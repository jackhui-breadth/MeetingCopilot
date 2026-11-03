import Foundation

struct MinutesGenerationError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

@MainActor
final class MinutesGenerator: ObservableObject {
    @Published private(set) var isGenerating = false
    @Published private(set) var progressMessage = ""

    private var serverProcess: Process?

    func generate(
        for meeting: MeetingRecord,
        template: MinutesTemplate = .general
    ) async throws -> String {
        let segments = meeting.sortedSegments
        guard !segments.isEmpty else {
            throw MinutesGenerationError(message: "请先生成逐字稿，再生成会议纪要。")
        }

        isGenerating = true
        progressMessage = "正在连接本机纪要模型…"
        defer {
            isGenerating = false
            progressMessage = ""
        }

        let endpoint = URL(
            string: UserDefaults.standard.string(
                forKey: "minutesEndpoint"
            ) ?? "http://127.0.0.1:11434/api/generate"
        )
        guard let endpoint, endpoint.host != nil else {
            throw MinutesGenerationError(message: "Ollama 接口地址无效。")
        }
        try await ensureOllamaServer(endpoint: endpoint)

        let model = UserDefaults.standard.string(
            forKey: "minutesModel"
        ) ?? "qwen3.5:9b"
        let transcriptParts = chunkTranscript(segments, meeting: meeting)
        let evidence: String

        if transcriptParts.count == 1 {
            evidence = transcriptParts[0]
        } else {
            var partialNotes: [String] = []
            for (index, part) in transcriptParts.enumerated() {
                progressMessage = "正在提取第 \(index + 1)/\(transcriptParts.count) 段会议证据…"
                let note = try await request(
                    endpoint: endpoint,
                    model: model,
                    prompt: """
                    /no_think
                    你是严谨的中文会议分析助手。下面是同一场会议的一部分逐字稿。
                    只提取有原文依据的议题、观点、明确决议、待办、负责人和期限。
                    每条结论保留对应的 [时间戳] 和发言人姓名。
                    没明确说出的负责人、期限或决议必须写“未明确”，禁止推测。
                    输出简洁要点，不要写客套话。

                    \(part)
                    """,
                    numPredict: 1_400
                )
                partialNotes.append("【第 \(index + 1) 段证据】\n\(note)")
            }
            evidence = partialNotes.joined(separator: "\n\n")
        }

        progressMessage = "正在整理会议纪要…"
        let participants = participantSummary(meeting)
        let finalPrompt = """
        /no_think
        你是高级中文会议秘书。请仅依据下面的逐字稿和分段证据生成会议纪要。

        会议信息：
        - 标题：\(meeting.title)
        - 时间：\(meeting.date.formatted(date: .long, time: .shortened))
        - 时长：\(formatDuration(meeting.durationSeconds))
        - 参会人：\(participants)

        本次纪要模板：\(template.title)
        模板关注重点：\(template.focus)

        必须使用以下 Markdown 结构：
        # \(meeting.title)
        \(template.sectionOutline)

        要求：
        1. 决议和待办尽量附发言时间，例如 [01:23]。
        2. 使用真实姓名；未认领发言人写“待确认发言人”。
        3. 负责人或期限没有明确说出时写“未明确”，不得编造。
        4. 严格区分讨论意见、已确认决议和待办任务。
        5. 最后一个部分必须包含 Markdown 待办表格，列为：任务、负责人、期限、依据时间。
        6. 没有明确决议时明确写“未形成明确决议”，不要为了完整而虚构。
        7. 只输出纪要正文。

        参会人：\(participants)

        逐字稿证据：
        \(evidence)
        """

        let markdown = try await request(
            endpoint: endpoint,
            model: model,
            prompt: finalPrompt,
            numPredict: 2_600
        )
        return cleanMarkdown(markdown)
    }

    private func ensureOllamaServer(endpoint: URL) async throws {
        if await isServerAvailable(endpoint: endpoint) {
            return
        }

        guard let host = endpoint.host,
              host == "127.0.0.1" || host == "localhost"
        else {
            throw MinutesGenerationError(
                message: "无法连接配置的 Ollama 接口：\(endpoint.absoluteString)"
            )
        }

        if serverProcess?.isRunning != true {
            let candidates = [
                "/usr/local/bin/ollama",
                "/opt/homebrew/bin/ollama",
                "/Applications/Ollama.app/Contents/Resources/ollama"
            ]
            guard let executable = candidates.first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            }) else {
                throw MinutesGenerationError(
                    message: "没有找到 Ollama。请先安装 Ollama 本地模型服务。"
                )
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["serve"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            serverProcess = process
        }

        for _ in 0..<24 {
            try await Task.sleep(for: .milliseconds(500))
            if await isServerAvailable(endpoint: endpoint) {
                return
            }
        }
        throw MinutesGenerationError(
            message: "本机 Ollama 服务启动超时，请确认 Ollama 已安装并可正常运行。"
        )
    }

    private func isServerAvailable(endpoint: URL) async -> Bool {
        let tagsURL = endpoint
            .deletingLastPathComponent()
            .appendingPathComponent("tags")
        var request = URLRequest(url: tagsURL)
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func request(
        endpoint: URL,
        model: String,
        prompt: String,
        numPredict: Int
    ) async throws -> String {
        struct GenerateRequest: Encodable {
            let model: String
            let prompt: String
            let stream: Bool
            let think: Bool
            let keepAlive: String
            let options: Options

            enum CodingKeys: String, CodingKey {
                case model, prompt, stream, think, options
                case keepAlive = "keep_alive"
            }
        }

        struct Options: Encodable {
            let temperature: Double
            let numCtx: Int
            let numPredict: Int
            let repeatPenalty: Double

            enum CodingKeys: String, CodingKey {
                case temperature
                case numCtx = "num_ctx"
                case numPredict = "num_predict"
                case repeatPenalty = "repeat_penalty"
            }
        }

        struct GenerateResponse: Decodable {
            let response: String
        }

        struct ErrorResponse: Decodable {
            let error: String
        }

        let payload = GenerateRequest(
            model: model,
            prompt: prompt,
            stream: false,
            think: false,
            keepAlive: "10m",
            options: Options(
                temperature: 0.15,
                numCtx: 32_768,
                numPredict: numPredict,
                repeatPenalty: 1.1
            )
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MinutesGenerationError(message: "纪要服务没有返回有效响应。")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let apiError = try? JSONDecoder().decode(
                ErrorResponse.self,
                from: data
            ) {
                throw MinutesGenerationError(
                    message: "纪要模型不可用：\(apiError.error)"
                )
            }
            throw MinutesGenerationError(
                message: "纪要模型返回错误（HTTP \(httpResponse.statusCode)）。"
            )
        }

        let result = try JSONDecoder().decode(
            GenerateResponse.self,
            from: data
        )
        let value = result.response.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty else {
            throw MinutesGenerationError(message: "纪要模型返回了空内容。")
        }
        return value
    }

    private func chunkTranscript(
        _ segments: [TranscriptSegment],
        meeting: MeetingRecord
    ) -> [String] {
        var chunks: [String] = []
        var current = ""
        for segment in segments {
            let line = "[\(formatDuration(segment.startTime))] "
                + "\(speakerName(segment.speakerId, meeting: meeting))："
                + segment.text
            if !current.isEmpty, current.count + line.count > 24_000 {
                chunks.append(current)
                current = line
            } else {
                current += current.isEmpty ? line : "\n\(line)"
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private func participantSummary(_ meeting: MeetingRecord) -> String {
        var seen = Set<String>()
        let names = meeting.sortedSegments.compactMap {
            (segment: TranscriptSegment) -> String? in
            guard seen.insert(segment.speakerId).inserted else {
                return nil
            }
            return speakerName(segment.speakerId, meeting: meeting)
        }
        return names.isEmpty ? "未识别" : names.joined(separator: "、")
    }

    private func speakerName(
        _ speakerID: String,
        meeting: MeetingRecord
    ) -> String {
        let mapped = meeting.speakerName(for: speakerID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !mapped.isEmpty {
            return mapped
        }
        return "待确认发言人（\(speakerID)）"
    }

    private func cleanMarkdown(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            result = result
                .replacingOccurrences(
                    of: #"^```(?:markdown|md)?\s*"#,
                    with: "",
                    options: .regularExpression
                )
                .replacingOccurrences(
                    of: #"\s*```$"#,
                    with: "",
                    options: .regularExpression
                )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
