import Foundation

enum IntelligentEditingQualityStage: String, Equatable {
    case classifySelection
    case nativeProofreadCheck
    case appleCandidateGeneration
    case deterministicMarkdownCleanup
    case lineformValidation
    case rankAndDedupe
    case failCleanly
}

struct IntelligentEditingQualityPlan: Equatable {
    let action: IntelligentEditingAction
    let allowsMultipleCandidates: Bool
    let stages: [IntelligentEditingQualityStage]
}

enum IntelligentEditingQualityPipeline {
    static func plan(for request: IntelligentEditingRequest, selectedText: String) -> IntelligentEditingQualityPlan {
        let action = request.evaluationAction
        var stages: [IntelligentEditingQualityStage] = [.classifySelection]

        switch action {
        case .proofread:
            stages.append(.nativeProofreadCheck)
            stages.append(.appleCandidateGeneration)
        case .rewrite, .summarize, .shorten:
            stages.append(.appleCandidateGeneration)
        case .cleanMarkdown:
            stages.append(.deterministicMarkdownCleanup)
        }

        stages.append(.lineformValidation)

        let allowsMultipleCandidates = IntelligentEditingPresentationPolicy.optionCount(
            for: request,
            selectedText: selectedText
        ) > 1
        if allowsMultipleCandidates {
            stages.append(.rankAndDedupe)
        }

        stages.append(.failCleanly)

        return IntelligentEditingQualityPlan(
            action: action,
            allowsMultipleCandidates: allowsMultipleCandidates,
            stages: stages
        )
    }
}
