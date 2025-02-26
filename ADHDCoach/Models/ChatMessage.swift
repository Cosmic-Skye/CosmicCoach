import Foundation

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let content: String
    let timestamp: Date
    let isUser: Bool
    
    init(id: UUID = UUID(), content: String, timestamp: Date = Date(), isUser: Bool) {
        self.id = id
        self.content = content
        self.timestamp = timestamp
        self.isUser = isUser
    }
    
    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
    
    // For serialization/deserialization
    enum CodingKeys: String, CodingKey {
        case id, content, timestamp, isUser
    }
}
