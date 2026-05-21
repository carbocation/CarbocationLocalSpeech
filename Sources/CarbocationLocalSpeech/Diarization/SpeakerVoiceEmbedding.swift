import Foundation

public struct SpeakerVoiceEmbedding: Codable, Hashable, Sendable {
    public var speaker: SpeakerID
    public var vector: [Float]
    public var modelIdentifier: String
    public var modelVersion: String?
    public var source: String?
    public var speechDuration: TimeInterval
    public var sampleCount: Int
    public var quality: Double?
    public var metadata: [String: String]

    public init(
        speaker: SpeakerID,
        vector: [Float],
        modelIdentifier: String,
        modelVersion: String? = nil,
        source: String? = nil,
        speechDuration: TimeInterval = 0,
        sampleCount: Int = 1,
        quality: Double? = nil,
        metadata: [String: String] = [:],
        normalize: Bool = true
    ) {
        self.speaker = speaker
        self.vector = normalize ? Self.normalized(vector) : vector
        self.modelIdentifier = modelIdentifier
        self.modelVersion = modelVersion
        self.source = source
        self.speechDuration = max(0, speechDuration)
        self.sampleCount = max(0, sampleCount)
        self.quality = quality
        self.metadata = metadata
    }

    public var dimension: Int {
        vector.count
    }

    public var isUsable: Bool {
        guard !vector.isEmpty else { return false }
        var magnitudeSquared: Float = 0
        for value in vector {
            guard value.isFinite else { return false }
            magnitudeSquared += value * value
        }
        return magnitudeSquared > 0
    }

    public func cosineSimilarity(to other: SpeakerVoiceEmbedding) -> Float? {
        Self.cosineSimilarity(vector, other.vector)
    }

    public func cosineDistance(to other: SpeakerVoiceEmbedding) -> Float? {
        cosineSimilarity(to: other).map { 1 - $0 }
    }

    public func replacingSpeaker(_ speaker: SpeakerID) -> SpeakerVoiceEmbedding {
        var updated = self
        updated.speaker = speaker
        return updated
    }

    public func merged(with other: SpeakerVoiceEmbedding) -> SpeakerVoiceEmbedding? {
        guard vector.count == other.vector.count else { return nil }
        let lhsWeight = max(max(Float(sampleCount), Float(speechDuration)), 1)
        let rhsWeight = max(max(Float(other.sampleCount), Float(other.speechDuration)), 1)
        let totalWeight = lhsWeight + rhsWeight
        guard totalWeight > 0 else { return nil }

        let mergedVector = zip(vector, other.vector).map { lhs, rhs in
            (lhs * lhsWeight + rhs * rhsWeight) / totalWeight
        }
        let mergedQuality: Double?
        switch (quality, other.quality) {
        case (.some(let lhs), .some(let rhs)):
            mergedQuality = (lhs * Double(lhsWeight) + rhs * Double(rhsWeight)) / Double(totalWeight)
        case (.some(let lhs), .none):
            mergedQuality = lhs
        case (.none, .some(let rhs)):
            mergedQuality = rhs
        case (.none, .none):
            mergedQuality = nil
        }

        var mergedMetadata = metadata
        for (key, value) in other.metadata where mergedMetadata[key] == nil {
            mergedMetadata[key] = value
        }

        return SpeakerVoiceEmbedding(
            speaker: speaker,
            vector: mergedVector,
            modelIdentifier: modelIdentifier,
            modelVersion: modelVersion ?? other.modelVersion,
            source: source ?? other.source,
            speechDuration: speechDuration + other.speechDuration,
            sampleCount: sampleCount + other.sampleCount,
            quality: mergedQuality,
            metadata: mergedMetadata
        )
    }

    public static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }

        var dot: Float = 0
        var lhsMagnitude: Float = 0
        var rhsMagnitude: Float = 0
        for index in lhs.indices {
            let lhsValue = lhs[index]
            let rhsValue = rhs[index]
            guard lhsValue.isFinite, rhsValue.isFinite else { return nil }
            dot += lhsValue * rhsValue
            lhsMagnitude += lhsValue * lhsValue
            rhsMagnitude += rhsValue * rhsValue
        }
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return nil }
        return dot / (sqrt(lhsMagnitude) * sqrt(rhsMagnitude))
    }

    public static func normalized(_ vector: [Float]) -> [Float] {
        var magnitudeSquared: Float = 0
        for value in vector {
            guard value.isFinite else { return vector }
            magnitudeSquared += value * value
        }
        guard magnitudeSquared > 0 else { return vector }
        let magnitude = sqrt(magnitudeSquared)
        return vector.map { $0 / magnitude }
    }
}

public struct SpeakerVoiceEmbeddingMatchingOptions: Codable, Hashable, Sendable {
    public var maximumCosineDistance: Float
    public var minimumDistanceMargin: Float
    public var minimumSpeechDuration: TimeInterval
    public var minimumSampleCount: Int
    public var minimumQuality: Double?
    public var allowsCrossModelMatching: Bool
    public var requiresDifferentSpeakerNamespace: Bool

    public init(
        maximumCosineDistance: Float = 0.18,
        minimumDistanceMargin: Float = 0.05,
        minimumSpeechDuration: TimeInterval = 1.0,
        minimumSampleCount: Int = 1,
        minimumQuality: Double? = nil,
        allowsCrossModelMatching: Bool = false,
        requiresDifferentSpeakerNamespace: Bool = true
    ) {
        self.maximumCosineDistance = max(0, maximumCosineDistance)
        self.minimumDistanceMargin = max(0, minimumDistanceMargin)
        self.minimumSpeechDuration = max(0, minimumSpeechDuration)
        self.minimumSampleCount = max(0, minimumSampleCount)
        self.minimumQuality = minimumQuality
        self.allowsCrossModelMatching = allowsCrossModelMatching
        self.requiresDifferentSpeakerNamespace = requiresDifferentSpeakerNamespace
    }
}

public struct SpeakerVoiceEmbeddingMatch: Codable, Hashable, Sendable {
    public var speaker: SpeakerID
    public var canonicalSpeaker: SpeakerID
    public var cosineDistance: Float
    public var distanceMargin: Float

    public init(
        speaker: SpeakerID,
        canonicalSpeaker: SpeakerID,
        cosineDistance: Float,
        distanceMargin: Float
    ) {
        self.speaker = speaker
        self.canonicalSpeaker = canonicalSpeaker
        self.cosineDistance = cosineDistance
        self.distanceMargin = distanceMargin
    }
}

public struct SpeakerVoiceEmbeddingReconciliationResult: Codable, Hashable, Sendable {
    public var reconciliation: SpeakerIdentityReconciliationOptions
    public var matches: [SpeakerVoiceEmbeddingMatch]

    public init(
        reconciliation: SpeakerIdentityReconciliationOptions = SpeakerIdentityReconciliationOptions(),
        matches: [SpeakerVoiceEmbeddingMatch] = []
    ) {
        self.reconciliation = reconciliation
        self.matches = matches
    }
}

public struct SpeakerVoiceEmbeddingCache: Codable, Hashable, Sendable {
    public private(set) var profiles: [SpeakerID: SpeakerVoiceEmbedding]

    public init(profiles: [SpeakerVoiceEmbedding] = []) {
        self.profiles = profiles.reduce(into: [SpeakerID: SpeakerVoiceEmbedding]()) { result, profile in
            guard profile.isUsable else { return }
            result[profile.speaker] = result[profile.speaker]?.merged(with: profile) ?? profile
        }
    }

    public mutating func reconcile(
        diarization: DiarizationResult,
        existingAliases: [String: String] = [:],
        options: SpeakerVoiceEmbeddingMatchingOptions = SpeakerVoiceEmbeddingMatchingOptions()
    ) -> SpeakerVoiceEmbeddingReconciliationResult {
        reconcile(
            profiles: diarization.speakerVoiceEmbeddings,
            existingAliases: existingAliases,
            options: options
        )
    }

    public mutating func reconcile(
        profiles inputProfiles: [SpeakerVoiceEmbedding],
        existingAliases: [String: String] = [:],
        options: SpeakerVoiceEmbeddingMatchingOptions = SpeakerVoiceEmbeddingMatchingOptions()
    ) -> SpeakerVoiceEmbeddingReconciliationResult {
        var aliases = SpeakerIdentityReconciliationOptions(aliases: existingAliases).aliases
        var matches: [SpeakerVoiceEmbeddingMatch] = []

        for profile in inputProfiles where isEligible(profile, options: options) {
            let canonicalID = Self.canonicalSpeakerID(for: profile.speaker, aliases: aliases)
            let canonicalProfile = profile.replacingSpeaker(canonicalID)

            if let existing = profiles[canonicalID] {
                profiles[canonicalID] = existing.merged(with: canonicalProfile) ?? canonicalProfile
                continue
            }

            if let match = bestMatch(for: canonicalProfile, options: options) {
                aliases[profile.speaker.rawValue] = match.canonicalSpeaker.rawValue
                matches.append(SpeakerVoiceEmbeddingMatch(
                    speaker: profile.speaker,
                    canonicalSpeaker: match.canonicalSpeaker,
                    cosineDistance: match.cosineDistance,
                    distanceMargin: match.distanceMargin
                ))
                let remappedProfile = profile.replacingSpeaker(match.canonicalSpeaker)
                profiles[match.canonicalSpeaker] = profiles[match.canonicalSpeaker]?.merged(with: remappedProfile)
                    ?? remappedProfile
            } else {
                profiles[canonicalID] = canonicalProfile
            }
        }

        return SpeakerVoiceEmbeddingReconciliationResult(
            reconciliation: SpeakerIdentityReconciliationOptions(aliases: aliases),
            matches: matches
        )
    }

    private func bestMatch(
        for profile: SpeakerVoiceEmbedding,
        options: SpeakerVoiceEmbeddingMatchingOptions
    ) -> SpeakerVoiceEmbeddingMatch? {
        let distances = profiles.compactMap { speakerID, cachedProfile -> (speakerID: SpeakerID, distance: Float)? in
            guard speakerID != profile.speaker,
                  cachedProfile.isUsable,
                  options.allowsCrossModelMatching || cachedProfile.modelIdentifier == profile.modelIdentifier,
                  !options.requiresDifferentSpeakerNamespace
                    || Self.speakerNamespace(for: speakerID) != Self.speakerNamespace(for: profile.speaker),
                  let distance = profile.cosineDistance(to: cachedProfile)
            else {
                return nil
            }
            return (speakerID, distance)
        }
        .sorted { lhs, rhs in
            if lhs.distance == rhs.distance {
                return lhs.speakerID.rawValue < rhs.speakerID.rawValue
            }
            return lhs.distance < rhs.distance
        }

        guard let best = distances.first,
              best.distance <= options.maximumCosineDistance
        else {
            return nil
        }

        let secondDistance = distances.dropFirst().first?.distance ?? .infinity
        let margin = secondDistance - best.distance
        guard margin >= options.minimumDistanceMargin else {
            return nil
        }

        return SpeakerVoiceEmbeddingMatch(
            speaker: profile.speaker,
            canonicalSpeaker: best.speakerID,
            cosineDistance: best.distance,
            distanceMargin: margin
        )
    }

    private func isEligible(
        _ profile: SpeakerVoiceEmbedding,
        options: SpeakerVoiceEmbeddingMatchingOptions
    ) -> Bool {
        guard profile.isUsable,
              profile.speechDuration >= options.minimumSpeechDuration,
              profile.sampleCount >= options.minimumSampleCount
        else {
            return false
        }
        if let minimumQuality = options.minimumQuality {
            guard let quality = profile.quality,
                  quality >= minimumQuality
            else {
                return false
            }
        }
        return true
    }

    private static func canonicalSpeakerID(for speakerID: SpeakerID, aliases: [String: String]) -> SpeakerID {
        let original = speakerID.rawValue
        var current = original
        var visited = Set<String>()

        while let next = aliases[current] {
            guard !visited.contains(next) else {
                return SpeakerID(rawValue: original)
            }
            visited.insert(current)
            current = next
        }

        return SpeakerID(rawValue: current)
    }

    private static func speakerNamespace(for speakerID: SpeakerID) -> String? {
        let rawValue = speakerID.rawValue
        guard let range = rawValue.range(of: "_speaker_", options: .backwards) else {
            return nil
        }
        let namespace = String(rawValue[..<range.lowerBound])
        return namespace.isEmpty ? nil : namespace
    }
}
