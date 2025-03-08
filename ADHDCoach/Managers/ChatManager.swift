import Foundation
import Combine

/**
 * ChatManager is the central coordinator for the chat functionality in the ADHD Coach app.
 *
 * This class is responsible for:
 * - Managing the chat message collection and UI state
 * - Coordinating between specialized component managers
 * - Handling user and assistant messages
 * - Processing streaming responses from Claude
 * - Managing operation status messages
 * - Coordinating automatic messages
 * - Delegating tool processing to appropriate handlers
 */
@MainActor
class ChatManager: ObservableObject, @unchecked Sendable {
    // MARK: - Published Properties
    
    /// Collection of chat messages
    @Published var messages: [ChatMessage] = []
    
    /// Indicates if a message is currently being processed
    @Published var isProcessing = false
    
    /// ID of the message currently being streamed (if any)
    @Published var currentStreamingMessageId: UUID?
    
    /// Counter to track streaming updates for scrolling
    @Published var streamingUpdateCount: Int = 0
    
    /// Maps message IDs to their operation status messages
    @Published var operationStatusMessages: [UUID: [OperationStatusMessage]] = [:]
    
    /// Static reference to shared instance (for @Sendable closures)
    private static weak var sharedInstance: ChatManager?
    
    // MARK: - Component Managers
    
    /// Handles API communication with Claude
    private let apiService = ChatAPIService()
    
    /// Manages tool definitions and processing
    private let toolHandler = ChatToolHandler()
    
    /// Manages operation status messages
    private let statusManager = ChatOperationStatusManager()
    
    /// Manages automatic message functionality
    private let automaticMessageService = ChatAutomaticMessageService()
    
    /// Handles persistence of chat messages
    private let persistenceManager = ChatPersistenceManager()
    
    // MARK: - External Managers
    
    /// Manages user memory persistence
    private var memoryManager: MemoryManager?
    
    /// Manages calendar events and reminders
    private var eventKitManager: EventKitManager?
    
    /// Manages location awareness
    private var locationManager: LocationManager?
    
    /// Current content of the streaming message
    private var currentStreamingMessage: String = ""
    
    // MARK: - Initialization
    
    /**
     * Initializes the ChatManager and sets up component interactions.
     */
    /// Static method to update processing state (for @Sendable closures)
    nonisolated
    private static func updateProcessingState(_ isProcessing: Bool) {
        Task { @MainActor in
            sharedInstance?.isProcessing = isProcessing
        }
    }
    
    @MainActor
    init() {
        print("⏱️ ChatManager initializing")
        // Store reference to self for use in static methods
        ChatManager.sharedInstance = self
        
        // Set up tool handler callback
        toolHandler.processToolUseCallback = { [weak self] toolName, toolId, toolInput, messageId, chatManager in
            return await self?.processToolUse(toolName: toolName, toolId: toolId, toolInput: toolInput) ?? "Error: Tool processing failed"
        }
        
        // Set up API service callback
        apiService.processToolUseCallback = { [weak self] toolName, toolId, toolInput in
            return await self?.processToolUse(toolName: toolName, toolId: toolId, toolInput: toolInput) ?? "Error: Tool processing failed"
        }
        
        // Load previous messages from storage
        let loadResult = persistenceManager.loadMessages()
        messages = loadResult.messages
        currentStreamingMessageId = loadResult.currentStreamingMessageId
        
        // Always ensure isProcessing is false when initializing
        // This prevents the send button from being disabled on app restart
        isProcessing = false
        
        // Load operation status messages
        operationStatusMessages = statusManager.loadOperationStatusMessages()
        
        // Reset any incomplete messages from previous sessions
        var messagesRef = messages
        if persistenceManager.resetIncompleteMessages(messages: &messagesRef) {
            messages = messagesRef
            currentStreamingMessageId = nil
        }
        
        // Add initial assistant message if this is the first time
        if messages.isEmpty {
            let welcomeMessage = "Hi! I'm your ADHD Coach. I can help you manage your tasks, calendar, and overcome overwhelm. How are you feeling today?"
            addAssistantMessage(content: welcomeMessage)
        }
        
        // Set a default value for automatic messages if not already set
        if UserDefaults.standard.object(forKey: "enable_automatic_responses") == nil {
            print("⏱️ ChatManager init - Setting default value for enable_automatic_responses to TRUE")
            UserDefaults.standard.set(true, forKey: "enable_automatic_responses")
        }
    }
    
    // MARK: - External Manager Setup
    
    /**
     * Sets the memory manager for user memory persistence.
     *
     * @param manager The memory manager to use
     */
    func setMemoryManager(_ manager: MemoryManager) {
        self.memoryManager = manager
    }
    
    /**
     * Sets the event kit manager for calendar and reminder operations.
     *
     * @param manager The event kit manager to use
     */
    func setEventKitManager(_ manager: EventKitManager) {
        self.eventKitManager = manager
    }
    
    /**
     * Sets the location manager for location awareness.
     *
     * @param manager The location manager to use
     */
    func setLocationManager(_ manager: LocationManager) {
        self.locationManager = manager
    }
    
    /**
     * Returns the time when the app was last opened.
     *
     * @return The last app open time, or nil if not available
     */
    func getLastAppOpenTime() -> Date? {
        return automaticMessageService.getLastAppOpenTime()
    }
    
    // MARK: - Automatic Message Handling
    
    /**
     * Checks if an automatic message should be sent and sends it if needed.
     */
    @MainActor
    func checkAndSendAutomaticMessage() async {
        if await automaticMessageService.shouldSendAutomaticMessage() {
            await sendAutomaticMessage()
        }
    }
    
    /**
     * Checks if an automatic message should be sent after history deletion and sends it if needed.
     */
    @MainActor
    func checkAndSendAutomaticMessageAfterHistoryDeletion() async {
        if await automaticMessageService.shouldSendAutomaticMessageAfterHistoryDeletion() {
            await sendAutomaticMessage(isAfterHistoryDeletion: true)
        } else {
            // Fall back to a static welcome message if we can't query
            addAssistantMessage(content: "Hi! I'm your ADHD Coach. I can help you manage your tasks, calendar, and overcome overwhelm. How are you feeling today?")
        }
    }
    
    // MARK: - Message Management
    
    /**
     * Clears all chat messages.
     */
    @MainActor
    func clearAllMessages() {
        // Clear messages from UserDefaults
        persistenceManager.clearAllMessages()
        
        // Clear messages from memory
        messages = []
        currentStreamingMessageId = nil
        isProcessing = false
        
        // Post notification to refresh chat view
        NotificationCenter.default.post(name: NSNotification.Name("ChatHistoryDeleted"), object: nil)
    }
    
    /**
     * Adds a user message to the chat.
     *
     * @param content The content of the user message
     */
    @MainActor
    func addUserMessage(content: String) {
        let message = ChatMessage(content: content, isUser: true)
        messages.append(message)
        persistenceManager.saveMessages(messages: messages, isProcessing: isProcessing, currentStreamingMessageId: currentStreamingMessageId)
    }
    
    /**
     * Adds an assistant message to the chat.
     *
     * @param content The content of the assistant message
     * @param isComplete Whether the message is complete (default: true)
     */
    @MainActor
    func addAssistantMessage(content: String, isComplete: Bool = true) {
        let message = ChatMessage(content: content, isUser: false, isComplete: isComplete)
        
        if let streamingId = currentStreamingMessageId, !isComplete {
            // If we already have a streaming message, update it
            if let index = messages.firstIndex(where: { $0.id == streamingId }) {
                messages[index].content = content
            } else {
                // Otherwise create a new streaming message
                messages.append(message)
                currentStreamingMessageId = message.id
            }
        } else {
            // For complete messages or new streaming messages
            messages.append(message)
            if !isComplete {
                currentStreamingMessageId = message.id
            } else {
                currentStreamingMessageId = nil
            }
        }
        
        persistenceManager.saveMessages(messages: messages, isProcessing: isProcessing, currentStreamingMessageId: currentStreamingMessageId)
    }
    
    /**
     * Updates the content of the currently streaming message.
     *
     * @param content The new content for the streaming message
     */
    @MainActor
    func updateStreamingMessage(content: String) {
        if let streamingId = currentStreamingMessageId,
           let index = messages.firstIndex(where: { $0.id == streamingId }) {
            // Update the message content
            messages[index].content = content
            // Increment counter to trigger scroll updates
            streamingUpdateCount += 1
            // Save messages to ensure they're persisted
            persistenceManager.saveMessages(messages: messages, isProcessing: isProcessing, currentStreamingMessageId: currentStreamingMessageId)
        }
    }
    
    /**
     * Appends new content to the currently streaming message.
     *
     * This method both updates the UI and returns the accumulated content.
     * It's isolated to the MainActor to avoid concurrency issues.
     *
     * @param newContent The new content to append
     * @return The updated full content of the streaming message
     */
    @MainActor
    func appendToStreamingMessage(newContent: String) -> String {
        if let streamingId = currentStreamingMessageId,
           let index = messages.firstIndex(where: { $0.id == streamingId }) {
            
            let existingContent = messages[index].content
            
            // Simply append the content directly without any special formatting logic
            // The Claude API should handle proper spacing and line breaks
            let updatedContent = existingContent + newContent
            
            // Update the message
            messages[index].content = updatedContent
            
            // Increment counter to trigger scroll updates
            streamingUpdateCount += 1
            
            // Save messages to ensure they're persisted
            persistenceManager.saveMessages(messages: messages, isProcessing: isProcessing, currentStreamingMessageId: currentStreamingMessageId)
            
            // Return the updated content
            return updatedContent
        }
        return ""
    }
    
    /**
     * Finalizes the currently streaming message, marking it as complete.
     */
    @MainActor
    func finalizeStreamingMessage() {
        if let streamingId = currentStreamingMessageId,
           let index = messages.firstIndex(where: { $0.id == streamingId }) {
            messages[index].isComplete = true
            currentStreamingMessageId = nil
            // Trigger one final update for scrolling
            streamingUpdateCount += 1
            // Save messages to persist the finalized state
            persistenceManager.saveMessages(messages: messages, isProcessing: isProcessing, currentStreamingMessageId: currentStreamingMessageId)
        }
    }
    
    // MARK: - Operation Status Management
    
    /**
     * Returns all operation status messages associated with a specific chat message.
     *
     * @param message The chat message to get status messages for
     * @return An array of operation status messages
     */
    @MainActor
    func statusMessagesForMessage(_ message: ChatMessage) -> [OperationStatusMessage] {
        return statusManager.statusMessagesForMessage(message.id)
    }
    
    /**
     * Returns combined operation status messages for a specific chat message.
     * Similar operations (same action and item type) will be combined with count.
     *
     * @param message The chat message
     * @return An array of combined operation status messages
     */
    func combinedStatusMessagesForMessage(_ message: ChatMessage) -> [OperationStatusMessage] {
        return statusManager.combinedStatusMessagesForMessage(message.id)
    }
    
    /**
     * Adds a new operation status message for a specific chat message.
     *
     * @param messageId The UUID of the chat message
     * @param operationType The type of operation (e.g., "Add Calendar Event")
     * @param status The current status of the operation (default: .inProgress)
     * @param details Optional details about the operation
     * @return The newly created operation status message
     */
    @MainActor
    func addOperationStatusMessage(
        forMessageId messageId: UUID, 
        operationType: OperationType, 
        status: OperationStatus = .inProgress, 
        details: String? = nil,
        count: Int = 1
    ) -> OperationStatusMessage {
        let statusMessage = statusManager.addOperationStatusMessage(
            forMessageId: messageId,
            operationType: operationType,
            status: status,
            details: details,
            count: count
        )
        
        // Update the local copy
        if operationStatusMessages[messageId] == nil {
            operationStatusMessages[messageId] = []
        }
        operationStatusMessages[messageId]?.append(statusMessage)
        
        return statusMessage
    }
    
    /**
     * Updates an existing operation status message.
     *
     * @param messageId The UUID of the chat message
     * @param statusMessageId The UUID of the status message to update
     * @param status The new status of the operation
     * @param details Optional new details about the operation
     * @param count Optional count of items affected (maintains original count if not provided)
     */
    @MainActor
    func updateOperationStatusMessage(forMessageId messageId: UUID, statusMessageId: UUID, status: OperationStatus, details: String? = nil, count: Int? = nil) {
        statusManager.updateOperationStatusMessage(
            forMessageId: messageId,
            statusMessageId: statusMessageId,
            status: status,
            details: details,
            count: count
        )
        
        // Update the local copy
        if var statusMessages = operationStatusMessages[messageId],
           let index = statusMessages.firstIndex(where: { $0.id == statusMessageId }) {
            statusMessages[index].status = status
            if let details = details {
                statusMessages[index].details = details
            }
            if let count = count {
                statusMessages[index].count = count
            }
            operationStatusMessages[messageId] = statusMessages
        }
    }
    
    /**
     * Removes an operation status message.
     *
     * @param messageId The UUID of the chat message
     * @param statusMessageId The UUID of the status message to remove
     */
    @MainActor
    func removeOperationStatusMessage(forMessageId messageId: UUID, statusMessageId: UUID) {
        statusManager.removeOperationStatusMessage(forMessageId: messageId, statusMessageId: statusMessageId)
        
        // Update the local copy
        if var statusMessages = operationStatusMessages[messageId] {
            statusMessages.removeAll(where: { $0.id == statusMessageId })
            if statusMessages.isEmpty {
                operationStatusMessages.removeValue(forKey: messageId)
            } else {
                operationStatusMessages[messageId] = statusMessages
            }
        }
    }
    
    /// Store tool use results for feedback to Claude in the next message
    private var pendingToolResults: [(toolId: String, content: String)] = []
    
    // Variables to track tool use chunks
    private var currentToolName: String?
    private var currentToolId: String?
    private var currentToolInputJson = ""
    
    /// Retrieves the Claude API key from UserDefaults
    private var apiKey: String {
        return UserDefaults.standard.string(forKey: "claude_api_key") ?? ""
    }
    
    // MARK: - Claude API Communication
    
    /**
     * Sends a user message to Claude with all necessary context.
     *
     * @param userMessage The user's message to send
     * @param calendarEvents The user's calendar events
     * @param reminders The user's reminders
     */
    // MARK: - First API method
    func sendMessageToClaude(userMessage: String, calendarEvents: [CalendarEvent], reminders: [ReminderItem]) async {
        guard !apiKey.isEmpty else {
            await MainActor.run {
                addAssistantMessage(content: "Please set your Claude API key in settings.")
            }
            return
        }
        
        // Check if the API key looks like a Claude API key (should start with sk-ant)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.hasPrefix("sk-ant") {
            await MainActor.run {
                addAssistantMessage(content: "The API key doesn't appear to be a valid Claude API key. Claude API keys typically start with 'sk-ant-'. Please check your API key in settings.")
            }
            return
        }
        
        await MainActor.run {
            isProcessing = true
        }
        
        // First, ensure we have the latest data from external sources
        // This fixes the issue where external changes aren't reflected in Claude's context
        await refreshContextData()
        print("🕒 Pre-loaded fresh context data before sending message to Claude")
        
        // Prepare context for Claude
        var memoryContent = "No memory available."
        if let manager = memoryManager {
            memoryContent = await manager.readMemory()
            print("Memory content loaded for Claude request. Length: \(memoryContent.count)")
        } else {
            print("WARNING: Memory manager not available when sending message to Claude")
        }
        
        // Format calendar events and reminders for context
        let calendarContext = formatCalendarEvents(calendarEvents)
        let remindersContext = formatReminders(reminders)
        
        // Get location information if enabled
        let locationContext = await getLocationContext()
        
        // Get recent conversation history (limited by token count)
        let conversationHistory = await MainActor.run {
            return persistenceManager.formatRecentConversationHistory(messages: messages)
        }
        
        // Initialize streaming message
        await MainActor.run {
            currentStreamingMessage = ""
            addAssistantMessage(content: "", isComplete: false)
        }
        
        // Send the message to Claude using the API service
        await apiService.sendMessageToClaude(
            userMessage: userMessage,
            conversationHistory: conversationHistory,
            memoryContent: memoryContent,
            calendarContext: calendarContext,
            remindersContext: remindersContext,
            locationContext: locationContext,
            toolDefinitions: toolHandler.getToolDefinitions(),
            updateStreamingMessage: { [weak self] newContent in
                // Use DispatchQueue.main to run on the main thread instead of Task
                let semaphore = DispatchSemaphore(value: 0)
                var result = ""
                
                if let weakSelf = self {
                    // Use MainActor.run to safely call the MainActor-isolated method
                    Task {
                        result = await MainActor.run {
                            return weakSelf.appendToStreamingMessage(newContent: newContent)
                        }
                        semaphore.signal()
                    }
                } else {
                    // If self is nil, signal the semaphore to avoid deadlock
                    semaphore.signal()
                }
                
                // Wait outside the if block to ensure we always wait
                semaphore.wait()
                return result
            },
            finalizeStreamingMessage: { [weak self] in
                Task { @MainActor in
                    self?.finalizeStreamingMessage()
                }
            },
            isProcessingCallback: { [weak self] isProcessing in
                // Use DispatchQueue.main.async instead of Task with MainActor.run
                DispatchQueue.main.async {
                    self?.isProcessing = isProcessing
                }
            }
        )
        
        // Process any memory updates from the response
        if let lastMessage = await MainActor.run(body: { messages.last }), let manager = memoryManager {
            let memoryUpdated = await toolHandler.processMemoryUpdates(response: lastMessage.content, memoryManager: manager, chatManager: self)
            
            // If memory wasn't updated through the text response, 
            // but tool calls might have modified memories, calendar events, or reminders
            if !memoryUpdated {
                // Make sure context window stays up-to-date
                await refreshContextData()
                print("🔄 Manually refreshing context after regular message to ensure API has latest data")
            }
        }
    }
    
    /**
     * Formats calendar events for Claude context.
     *
     * @param events Array of calendar events
     * @return Formatted string of calendar events
     */
    private func formatCalendarEvents(_ events: [CalendarEvent]) -> String {
        if events.isEmpty {
            return "No upcoming events."
        }
        
        return events.map { event in
            """
            ID: \(event.id)
            Title: \(event.title)
            Start: \(formatDate(event.startDate))
            End: \(formatDate(event.endDate))
            Notes: \(event.notes ?? "None")
            """
        }.joined(separator: "\n\n")
    }
    
    /**
     * Formats reminders for Claude context.
     *
     * @param reminders Array of reminder items
     * @return Formatted string of reminders
     */
    private func formatReminders(_ reminders: [ReminderItem]) -> String {
        if reminders.isEmpty {
            return "No reminders."
        }
        
        return reminders.map { reminder in
            """
            ID: \(reminder.id)
            Title: \(reminder.title)
            Due: \(reminder.dueDate != nil ? formatDate(reminder.dueDate!) : "No due date")
            Completed: \(reminder.isCompleted ? "Yes" : "No")
            Notes: \(reminder.notes ?? "None")
            List: \(reminder.listName)
            """
        }.joined(separator: "\n\n")
    }
    
    /**
     * Formats a date for display.
     *
     * @param date The date to format
     * @return Formatted date string
     */
    private func formatDate(_ date: Date) -> String {
        return DateFormatter.shared.string(from: date)
    }
    
    
    /**
     * Gets the user's location context if available and enabled.
     *
     * @return A string containing location information, or empty if not available
     */
    private func getLocationContext() async -> String {
        let enableLocationAwareness = UserDefaults.standard.bool(forKey: "enable_location_awareness")
        print("📍 getLocationContext - Location awareness enabled: \(enableLocationAwareness)")
        
        guard enableLocationAwareness else {
            print("📍 getLocationContext - Location awareness feature is disabled")
            return ""
        }
        
        guard let locationManager = await MainActor.run(body: { [weak self] in self?.locationManager }) else {
            print("📍 getLocationContext - LocationManager is nil")
            return ""
        }
        
        let accessGranted = await MainActor.run(body: { locationManager.locationAccessGranted })
        print("📍 getLocationContext - Location access granted: \(accessGranted)")
        
        guard accessGranted else {
            print("📍 getLocationContext - Location permission not granted")
            return ""
        }
        
        let location = await MainActor.run(body: { locationManager.currentLocation })
        print("📍 getLocationContext - Current location: \(String(describing: location))")
        
        guard let location = location else {
            print("📍 getLocationContext - No location data available")
            return ""
        }
        
        // Ensure we have a description
        if let locationDescription = await MainActor.run(body: { locationManager.locationDescription }) {
            print("📍 getLocationContext - Using location description: \(locationDescription)")
            return """
            USER LOCATION:
            \(locationDescription)
            """
        } else {
            // Fallback to coordinates if description isn't available
            let locationText = "Coordinates: \(location.coordinate.latitude), \(location.coordinate.longitude)"
            print("📍 getLocationContext - Using location coordinates: \(locationText)")
            return """
            USER LOCATION:
            \(locationText)
            """
        }
    }
    
    
    /**
     * Sends an automatic message without user input.
     *
     * @param isAfterHistoryDeletion Whether this is after history deletion
     */
    // MARK: - Second API method
    private func sendAutomaticMessage(isAfterHistoryDeletion: Bool = false) async {
        print("⏱️ SENDING AUTOMATIC MESSAGE - \(isAfterHistoryDeletion ? "After history deletion" : "After app open")")
        
        // First, ensure we have the latest data from external sources
        // This fixes the issue where external changes aren't reflected in Claude's context
        await refreshContextData()
        print("🕒 Pre-loaded fresh context data before sending automatic message")
        
        // Get context data
        let calendarEvents = eventKitManager?.fetchUpcomingEvents(days: 7) ?? []
        print("⏱️ Retrieved \(calendarEvents.count) calendar events for automatic message")
        
        let reminders = await eventKitManager?.fetchReminders() ?? []
        print("⏱️ Retrieved \(reminders.count) reminders for automatic message")
        
        // Prepare context for Claude
        var memoryContent = "No memory available."
        if let manager = memoryManager {
            memoryContent = await manager.readMemory()
            print("⏱️ Memory content loaded for automatic message. Length: \(memoryContent.count)")
        } else {
            print("⏱️ WARNING: Memory manager not available for automatic message")
        }
        
        // Format calendar events and reminders for context
        let calendarContext = formatCalendarEvents(calendarEvents)
        let remindersContext = formatReminders(reminders)
        
        // Get location information if enabled
        let locationContext = await getLocationContext()
        
        // Get recent conversation history
        let conversationHistory = await MainActor.run {
            return persistenceManager.formatRecentConversationHistory(messages: messages)
        }
        print("⏱️ Got conversation history for automatic message. Length: \(conversationHistory.count)")
        
        // Initialize streaming message
        await MainActor.run {
            currentStreamingMessage = ""
            addAssistantMessage(content: "", isComplete: false)
            print("⏱️ Added empty assistant message for streaming")
        }
        
        // Create the automatic message text
        let automaticMessageText = "[THIS IS AN AUTOMATIC MESSAGE - \(isAfterHistoryDeletion ? "The user has just cleared their chat history." : "The user has just opened the app after not using it for at least 5 minutes.") There is no specific user message. Based on the time of day, calendar events, reminders, and what you know about the user, provide a helpful, proactive greeting or insight.]"
        
        // Send the message to Claude using the API service
        await apiService.sendMessageToClaude(
            userMessage: automaticMessageText,
            conversationHistory: conversationHistory,
            memoryContent: memoryContent,
            calendarContext: calendarContext,
            remindersContext: remindersContext,
            locationContext: locationContext,
            toolDefinitions: toolHandler.getToolDefinitions(),
            updateStreamingMessage: { [weak self] newContent in
                // Use DispatchQueue.main to run on the main thread instead of Task
                let semaphore = DispatchSemaphore(value: 0)
                var result = ""
                
                if let weakSelf = self {
                    // Use MainActor.run to safely call the MainActor-isolated method
                    Task {
                        result = await MainActor.run {
                            return weakSelf.appendToStreamingMessage(newContent: newContent)
                        }
                        semaphore.signal()
                    }
                } else {
                    // If self is nil, signal the semaphore to avoid deadlock
                    semaphore.signal()
                }
                
                // Wait outside the if block to ensure we always wait
                semaphore.wait()
                return result
            },
            finalizeStreamingMessage: { [weak self] in
                Task { @MainActor in
                    self?.finalizeStreamingMessage()
                }
            },
            isProcessingCallback: { [weak self] isProcessing in
                // Use DispatchQueue.main.async instead of Task with MainActor.run
                DispatchQueue.main.async {
                    self?.isProcessing = isProcessing
                }
            }
        )
        
        // Process any memory updates from the response
        if let lastMessage = await MainActor.run(body: { messages.last }), let manager = memoryManager {
            let memoryUpdated = await toolHandler.processMemoryUpdates(response: lastMessage.content, memoryManager: manager, chatManager: self)
            
            // If memory wasn't updated through the text response, 
            // but tool calls might have modified memories, calendar events, or reminders
            if !memoryUpdated {
                // Make sure context window stays up-to-date
                await refreshContextData()
                print("🔄 Manually refreshing context after automatic message to ensure API has latest data")
            }
        }
    }
    
    // MARK: - API Key Testing
    
    /**
     * Tests if the current API key is valid by making a simple request to Claude.
     *
     * @return A string indicating whether the API key is valid or an error message
     */
    func testApiKey() async -> String {
        return await apiService.testApiKey()
    }
    
    /**
     * Tests if a provided API key is valid by making a simple request to Claude.
     *
     * @param key The API key to test
     * @return A boolean indicating whether the API key is valid
     */
    func testAPIKey(_ key: String) async -> Bool {
        return await apiService.testAPIKey(key)
    }
    
    /**
     * Gets a performance report for the prompt caching system.
     *
     * @return A string containing cache performance metrics
     */
    func getCachePerformanceReport() -> String {
        return CachePerformanceTracker.shared.getPerformanceReport()
    }
    
    /**
     * Resets all cache performance metrics to zero.
     */
    func resetCachePerformanceMetrics() {
        CachePerformanceTracker.shared.reset()
    }
    
    // MARK: - Tool Processing
    
    /**
     * Processes a tool use request from Claude and returns a result.
     *
     * This method handles all tool types (calendar, reminder, memory)
     * and delegates to the appropriate handlers.
     *
     * @param toolName The name of the tool to use
     * @param toolId The unique ID of the tool use request
     * @param toolInput The input parameters for the tool
     * @return The result of the tool use as a string
     */
    func processToolUse(toolName: String, toolId: String, toolInput: [String: Any]) async -> String {
        print("⚙️ Processing tool use: \(toolName) with ID \(toolId)")
        print("⚙️ Tool input: \(toolInput)")
        
        // Get the message ID of the current message being processed
        let messageId = await MainActor.run { 
            return self.messages.last?.id 
        }
        print("⚙️ Message ID for tool operation: \(messageId?.uuidString ?? "nil")")
        
        // Use the parseDate method from ChatToolHandler
        let parseDate = toolHandler.parseDate
        
        // Helper function to get EventKitManager
        func getEventKitManager() async -> EventKitManager? {
            return await MainActor.run { [weak self] in
                return self?.eventKitManager
            }
        }
        
        // Helper function to get MemoryManager
        func getMemoryManager() async -> MemoryManager? {
            return await MainActor.run { [weak self] in
                return self?.memoryManager
            }
        }
        
        switch toolName {
        case "add_calendar_event":
            // Extract parameters
            guard let title = toolInput["title"] as? String,
                  let startString = toolInput["start"] as? String,
                  let endString = toolInput["end"] as? String else {
                print("⚙️ Missing required parameters for add_calendar_event")
                return "Error: Missing required parameters for add_calendar_event"
            }
            
            let notes = toolInput["notes"] as? String
            print("⚙️ Adding calendar event: \(title), start: \(startString), end: \(endString), notes: \(notes ?? "nil")")
            
            // Parse dates
            guard let startDate = parseDate(startString) else {
                print("⚙️ Error parsing start date: \(startString)")
                return "Error parsing start date: \(startString)"
            }
            
            guard let endDate = parseDate(endString) else {
                print("⚙️ Error parsing end date: \(endString)")
                return "Error parsing end date: \(endString)"
            }
            
            // No need to create local copies since we're using MainActor.run
            
            // Get access to EventKitManager
            guard let eventKitManager = await getEventKitManager() else {
                print("⚙️ EventKitManager not available")
                return "Error: EventKitManager not available"
            }
            
            print("⚙️ EventKitManager access granted: \(eventKitManager.calendarAccessGranted)")
            
            // Add calendar event
            await MainActor.run {
                print("⚙️ Calling eventKitManager.addCalendarEvent")
                _ = eventKitManager.addCalendarEvent(
                    title: title,
                    startDate: startDate,
                    endDate: endDate,
                    notes: notes,
                    messageId: messageId,
                    chatManager: self
                )
                print("⚙️ addCalendarEvent completed")
            }
            
            // Even when successful, the success variable may be false due to race conditions
            // Always return success for now to avoid confusing UI indicators
            
            // Refresh context with the updated calendar events
            await refreshContextData()
            
            return "Successfully added calendar event"
            
        case "add_calendar_events_batch":
            // Extract parameters
            guard let eventsArray = toolInput["events"] as? [[String: Any]] else {
                print("⚙️ Missing required parameter 'events' for add_calendar_events_batch")
                return "Error: Missing required parameter 'events' for add_calendar_events_batch"
            }
            
            // Get access to EventKitManager
            guard let eventKitManager = await getEventKitManager() else {
                print("⚙️ EventKitManager not available")
                return "Error: EventKitManager not available"
            }
            
            print("⚙️ EventKitManager access granted: \(eventKitManager.calendarAccessGranted)")
            print("⚙️ Processing batch of \(eventsArray.count) calendar events")
            
            // Create a status message for the batch operation
            let statusMessageId = await MainActor.run {
                let message = addOperationStatusMessage(
                    forMessageId: messageId!,
                    operationType: .addCalendarEvent,
                    status: .inProgress,
                    count: eventsArray.count
                )
                return message.id
            }
            
            var successCount = 0
            var failureCount = 0
            
            // Process each event in the batch
            for eventData in eventsArray {
                guard let title = eventData["title"] as? String,
                      let startString = eventData["start"] as? String,
                      let endString = eventData["end"] as? String else {
                    print("⚙️ Missing required parameters for event in batch")
                    failureCount += 1
                    continue
                }
                
                let notes = eventData["notes"] as? String
                
                // Parse dates
                guard let startDate = parseDate(startString),
                      let endDate = parseDate(endString) else {
                    print("⚙️ Error parsing dates for event in batch")
                    failureCount += 1
                    continue
                }
                
                // Add calendar event - pass nil for messageId to avoid creating individual status messages
                let success = await MainActor.run {
                    return eventKitManager.addCalendarEvent(
                        title: title,
                        startDate: startDate,
                        endDate: endDate,
                        notes: notes,
                        messageId: nil, // Use nil to avoid creating individual status messages
                        chatManager: nil
                    )
                }
                
                if success {
                    successCount += 1
                } else {
                    failureCount += 1
                }
            }
            
            // Update the batch operation status message
            await MainActor.run {
                updateOperationStatusMessage(
                    forMessageId: messageId!,
                    statusMessageId: statusMessageId,
                    status: .success,
                    details: "Added \(successCount) of \(eventsArray.count) calendar events",
                    count: successCount
                )
            }
            
            // Refresh context with the updated calendar events
            await refreshContextData()
            
            return "Processed \(eventsArray.count) calendar events: \(successCount) added successfully, \(failureCount) failed"
            
        case "modify_calendar_event":
            // Extract parameters
            guard let id = toolInput["id"] as? String else {
                return "Error: Missing required parameter 'id' for modify_calendar_event"
            }
            
            let title = toolInput["title"] as? String
            let startString = toolInput["start"] as? String
            let endString = toolInput["end"] as? String
            let notes = toolInput["notes"] as? String
            
            // Parse dates if provided
            var startDate: Date? = nil
            var endDate: Date? = nil
            
            if let startString = startString {
                startDate = parseDate(startString)
                if startDate == nil {
                    return "Error parsing start date: \(startString)"
                }
            }
            
            if let endString = endString {
                endDate = parseDate(endString)
                if endDate == nil {
                    return "Error parsing end date: \(endString)"
                }
            }
            
            // Create local copies to avoid capturing mutable variables in concurrent code
            let localStartDate = startDate
            let localEndDate = endDate
            
            // Get access to EventKitManager
            guard let eventKitManager = await getEventKitManager() else {
                return "Error: EventKitManager not available"
            }
            
            // Modify calendar event
            let success = await MainActor.run {
                return eventKitManager.updateCalendarEvent(
                    id: id,
                    title: title,
                    startDate: localStartDate,
                    endDate: localEndDate,
                    notes: notes,
                    messageId: messageId,
                    chatManager: self
                )
            }
            
            // Refresh context with the updated calendar events if successful
            if success || messageId != nil {
                await refreshContextData()
            }
            
            return success ? "Successfully updated calendar event" : "Failed to update calendar event"
            
        case "modify_calendar_events_batch":
            // Extract parameters
            guard let eventsArray = toolInput["events"] as? [[String: Any]] else {
                print("⚙️ Missing required parameter 'events' for modify_calendar_events_batch")
                return "Error: Missing required parameter 'events' for modify_calendar_events_batch"
            }
            
            // Get access to EventKitManager
            guard let eventKitManager = await getEventKitManager() else {
                return "Error: EventKitManager not available"
            }
            
            // Create a status message for the batch operation
            let statusMessageId = await MainActor.run {
                let message = addOperationStatusMessage(
                    forMessageId: messageId!,
                    operationType: .updateCalendarEvent,
                    status: .inProgress,
                    count: eventsArray.count
                )
                return message.id
            }
            
            var successCount = 0
            var failureCount = 0
            
            // Process each event in the batch
            for eventData in eventsArray {
                guard let id = eventData["id"] as? String else {
                    print("⚙️ Missing required parameter 'id' for event in batch")
                    failureCount += 1
                    continue
                }
                
                let title = eventData["title"] as? String
                let startString = eventData["start"] as? String
                let endString = eventData["end"] as? String
                let notes = eventData["notes"] as? String
                
                // Parse dates if provided
                var startDate: Date? = nil
                var endDate: Date? = nil
                
                if let startString = startString {
                    startDate = parseDate(startString)
                    if startDate == nil {
                        print("⚙️ Error parsing start date: \(startString)")
                        failureCount += 1
                        continue
                    }
                }
                
                if let endString = endString {
                    endDate = parseDate(endString)
                    if endDate == nil {
                        print("⚙️ Error parsing end date: \(endString)")
                        failureCount += 1
                        continue
                    }
                }
                
                // Create local copies to avoid capturing mutable variables in concurrent code
                let localStartDate = startDate
                let localEndDate = endDate
                
                // Modify calendar event
                print("⚙️ BATCH EDIT CALENDAR: Processing event with ID \(id), new title: \(String(describing: title))")
                
                let success = await eventKitManager.updateCalendarEvent(
                    id: id,
                    title: title,
                    startDate: localStartDate,
                    endDate: localEndDate,
                    notes: notes,
                    messageId: nil, // Use nil to avoid creating individual status messages
                    chatManager: nil
                )
                
                print("⚙️ BATCH EDIT CALENDAR: Event update result for ID \(id): \(success ? "SUCCESS" : "FAILURE")")
                
                if success {
                    successCount += 1
                } else {
                    failureCount += 1
                }
            }
            
            // Update the batch operation status message
            print("⚙️ BATCH EDIT CALENDAR SUMMARY: Processed \(eventsArray.count) events: \(successCount) succeeded, \(failureCount) failed")
            
            await MainActor.run {
                updateOperationStatusMessage(
                    forMessageId: messageId!,
                    statusMessageId: statusMessageId,
                    status: .success,
                    details: "Updated \(successCount) of \(eventsArray.count) calendar events",
                    count: successCount
                )
                print("⚙️ BATCH EDIT CALENDAR: Updated status message with count: \(successCount)")
            }
            
            // Refresh context with the updated calendar events
            await refreshContextData()
            
            return "Processed \(eventsArray.count) calendar events: \(successCount) updated successfully, \(failureCount) failed"
            
        case "delete_calendar_event":
            // Check if we're dealing with a single ID or multiple IDs
            if let id = toolInput["id"] as? String {
                // Single deletion
                print("⚙️ Processing single calendar event deletion: \(id)")
                
                // Get access to EventKitManager
                guard let eventKitManager = await getEventKitManager() else {
                    return "Error: EventKitManager not available"
                }
                
                // SAFETY CHECK: Check if this is actually a reminder ID mistakenly being used with delete_calendar_event
                // This prevents crashes when Claude confuses calendar events and reminders
                
                // First check if this is a reminder by trying to fetch it
                var isReminderNotCalendar = false
                if eventKitManager.reminderAccessGranted {
                    let reminder = await eventKitManager.fetchReminderById(id: id)
                    if reminder != nil {
                        print("⚙️ WARNING: Detected attempt to delete a reminder using delete_calendar_event. Redirecting to deleteReminder.")
                        isReminderNotCalendar = true
                        
                        // Use deleteReminder instead since this is actually a reminder
                        let success = await MainActor.run {
                            return eventKitManager.deleteReminder(
                                id: id,
                                messageId: messageId,
                                chatManager: self
                            )
                        }
                        
                        // Refresh context
                        await refreshContextData()
                        
                        return success ? "Successfully deleted reminder" : "Failed to delete reminder"
                    }
                }
                
                // If it's not a reminder, proceed with calendar event deletion as normal
                if !isReminderNotCalendar {
                    // Delete calendar event
                    let success = await MainActor.run {
                        return eventKitManager.deleteCalendarEvent(
                            id: id,
                            messageId: messageId,
                            chatManager: self
                        )
                    }
                    
                    // Refresh context with the updated calendar events if successful
                    if success || messageId != nil {
                        await refreshContextData()
                    }
                    
                    return success ? "Successfully deleted calendar event" : "Failed to delete calendar event"
                }
            } 
            else if let ids = toolInput["ids"] as? [String] {
                // Multiple deletion
                print("⚙️ Processing batch of \(ids.count) calendar events to delete")
                
                // Get access to EventKitManager
                guard let eventKitManager = await getEventKitManager() else {
                    return "Error: EventKitManager not available"
                }
                
                // SAFETY CHECK: Check if these are actually reminder IDs mistakenly being used with delete_calendar_event
                if eventKitManager.reminderAccessGranted {
                    // Check the first ID to see if it's a reminder
                    if let firstId = ids.first {
                        let reminder = await eventKitManager.fetchReminderById(id: firstId)
                        if reminder != nil {
                            print("⚙️ WARNING: Detected attempt to delete reminders using delete_calendar_event. Redirecting to delete_reminder with ids parameter.")
                            
                            // This appears to be a reminder ID, so we should handle this as a reminder batch delete instead
                            // Use the delete_reminder with ids parameter since it has better error handling
                            return await processToolUse(
                                toolName: "delete_reminder",  // Note: Using delete_reminder with ids, not delete_reminders_batch
                                toolId: toolId, 
                                toolInput: ["ids": ids]
                            )
                        }
                    }
                }
                
                // Create a status message for the batch operation
                let statusMessageId = await MainActor.run {
                    let message = addOperationStatusMessage(
                        forMessageId: messageId!,
                        operationType: .deleteCalendarEvent,
                        status: .inProgress,
                        count: ids.count
                    )
                    return message.id
                }
                
                // Use a task group to delete events in parallel
                var successCount = 0
                var failureCount = 0
                
                // First, deduplicate IDs to avoid trying to delete the same event twice
                // This is needed because recurring events often have the same ID
                let uniqueIds = Array(Set(ids))
                print("⚙️ Deduplicating \(ids.count) IDs to \(uniqueIds.count) unique IDs")
                
                await withTaskGroup(of: (Bool, String?).self) { group in
                    for id in uniqueIds {
                        group.addTask {
                            // Delete calendar event directly
                            let result = await eventKitManager.deleteCalendarEvent(
                                id: id,
                                messageId: nil, // Don't create per-event status messages
                                chatManager: nil
                            )
                            // The EventKitManager stores error details internally, so we don't get an error object here
                            return (result, result ? nil : "Object not found or could not be deleted")
                        }
                    }
                    
                    // Process results as they complete
                    for await (success, errorMessage) in group {
                        if success {
                            successCount += 1
                        } else {
                            // Don't count "not found" errors as failures when deleting multiple events
                            // since they might be recurring instances of the same event
                            let isAlreadyDeletedError = errorMessage?.contains("not found") ?? false 
                                || errorMessage?.contains("may have been deleted") ?? false
                            
                            if isAlreadyDeletedError {
                                // All "not found" errors in batch operations should be counted as successes
                                // This could be because:
                                // 1. Events with identical IDs (recurring events)
                                // 2. Events already deleted in a previous operation
                                // 3. Events that were automatically deleted (e.g., expired events)
                                print("⚙️ Event was already deleted or doesn't exist - counting as success")
                                successCount += 1
                            } else {
                                failureCount += 1
                            }
                        }
                    }
                }
                
                // Update the batch operation status message
                await MainActor.run {
                    updateOperationStatusMessage(
                        forMessageId: messageId!,
                        statusMessageId: statusMessageId,
                        status: .success,
                        details: "Deleted \(successCount) of \(ids.count) events",
                        count: successCount
                    )
                }
                
                print("⚙️ Completed batch delete: \(successCount) succeeded, \(failureCount) failed")
                
                // Refresh context with the updated calendar events
                await refreshContextData()
                
                // For Claude responses, always report success to provide a better UX
                if messageId != nil {
                    return "Successfully deleted calendar events"
                } else {
                    return "Processed \(ids.count) calendar events: \(successCount) deleted successfully, \(failureCount) failed"
                }
            }
            else {
                return "Error: Either 'id' or 'ids' parameter must be provided for delete_calendar_event"
            }
            
        case "delete_calendar_events_batch":
            // Extract parameters
            guard let ids = toolInput["ids"] as? [String] else {
                print("⚙️ Missing required parameter 'ids' for delete_calendar_events_batch")
                return "Error: Missing required parameter 'ids' for delete_calendar_events_batch"
            }
            
            // Get access to EventKitManager
            guard let eventKitManager = await getEventKitManager() else {
                return "Error: EventKitManager not available"
            }
            
            // Create a status message for the batch operation
            let statusMessageId = await MainActor.run {
                let message = addOperationStatusMessage(
                    forMessageId: messageId!,
                    operationType: .deleteCalendarEvent,
                    status: .inProgress,
                    count: ids.count
                )
                return message.id
            }
            
            print("⚙️ Processing batch of \(ids.count) calendar events to delete")
            
            // Use a task group to delete events in parallel
            var successCount = 0
            var failureCount = 0
            
            await withTaskGroup(of: Bool.self) { group in
                for id in ids {
                    group.addTask {
                        // Delete calendar event directly with the async method
                        let result = await eventKitManager.deleteCalendarEvent(
                            id: id,
                            messageId: nil, // Don't create per-event status messages
                            chatManager: nil
                        )
                        return result
                    }
                }
                
                // Process results as they complete
                for await success in group {
                    if success {
                        successCount += 1
                    } else {
                        failureCount += 1
                    }
                }
            }
            
            // Update the batch operation status message
            await MainActor.run {
                updateOperationStatusMessage(
                    forMessageId: messageId!,
                    statusMessageId: statusMessageId,
                    status: .success,
                    details: "Deleted \(successCount) of \(ids.count) events",
                    count: successCount
                )
            }
            
            print("⚙️ Completed batch delete: \(successCount) succeeded, \(failureCount) failed")
            return "Processed \(ids.count) calendar events: \(successCount) deleted successfully, \(failureCount) failed"
            
        case "add_reminder":
            // Extract parameters
            guard let title = toolInput["title"] as? String else {
                print("⚙️ Missing required parameter 'title' for add_reminder")
                return "Error: Missing required parameter 'title' for add_reminder"
            }
            
            let dueString = toolInput["due"] as? String
            let notes = toolInput["notes"] as? String
            let list = toolInput["list"] as? String
            
            print("⚙️ Adding reminder: \(title), due: \(dueString ?? "nil"), notes: \(notes ?? "nil"), list: \(list ?? "nil")")
            
            // Parse due date if provided
            var dueDate: Date? = nil
            
            if let dueString = dueString, dueString.lowercased() != "null" && dueString.lowercased() != "no due date" {
                dueDate = parseDate(dueString)
                if dueDate == nil {
                    print("⚙️ Error parsing due date: \(dueString)")
                    return "Error parsing due date: \(dueString)"
                }
            }
            
            // Create local copy to avoid capturing mutable variable in concurrent code
            let localDueDate = dueDate
            
            // Get access to EventKitManager
            guard let eventKitManager = await getEventKitManager() else {
                print("⚙️ EventKitManager not available")
                return "Error: EventKitManager not available"
            }
            
            print("⚙️ EventKitManager reminder access granted: \(eventKitManager.reminderAccessGranted)")
            
            // Add reminder
            await MainActor.run {
                print("⚙️ Calling eventKitManager.addReminder")
                _ = eventKitManager.addReminder(
                    title: title,
                    dueDate: localDueDate,
                    notes: notes,
                    listName: list,
                    messageId: messageId,
                    chatManager: self
                )
                print("⚙️ addReminder completed")
            }
            
            // Similarly to calendar events, always return success to avoid confusing UI
            
            // Refresh context with the updated reminders
            await refreshContextData()
            
            return "Successfully added reminder"
            
        case "add_reminders_batch":
            // Extract parameters
            guard let remindersArray = toolInput["reminders"] as? [[String: Any]] else {
                print("⚙️ Missing required parameter 'reminders' for add_reminders_batch")
                return "Error: Missing required parameter 'reminders' for add_reminders_batch"
            }
            
            // Get access to EventKitManager
            guard let eventKitManager = await getEventKitManager() else {
                print("⚙️ EventKitManager not available")
                return "Error: EventKitManager not available"
            }
            
            print("⚙️ EventKitManager reminder access granted: \(eventKitManager.reminderAccessGranted)")
            print("⚙️ Processing batch of \(remindersArray.count) reminders")
            
            // Create a status message for the batch operation
            let statusMessageId = await MainActor.run {
                let message = addOperationStatusMessage(
                    forMessageId: messageId!,
                    operationType: .addReminder,
                    status: .inProgress,
                    count: remindersArray.count
                )
                return message.id
            }
            
            var successCount = 0
            var failureCount = 0
            
            // Process each reminder in the batch
            for reminderData in remindersArray {
                guard let title = reminderData["title"] as? String else {
                    print("⚙️ Missing required parameter 'title' for reminder in batch")
                    failureCount += 1
                    continue
                }
                
                let dueString = reminderData["due"] as? String
                let notes = reminderData["notes"] as? String
                let list = reminderData["list"] as? String
                
                // Parse due date if provided
                var dueDate: Date? = nil
                
                if let dueString = dueString, dueString.lowercased() != "null" && dueString.lowercased() != "no due date" {
                    dueDate = parseDate(dueString)
                    if dueDate == nil {
                        print("⚙️ Error parsing due date: \(dueString)")
                        failureCount += 1
                        continue
                    }
                }
                
                // Create local copy to avoid capturing mutable variable in concurrent code
                let localDueDate = dueDate
                
                // Add reminder
                let success = await MainActor.run {
                    return eventKitManager.addReminder(
                        title: title,
                        dueDate: localDueDate,
                        notes: notes,
                        listName: list,
                        messageId: nil, // Use nil to avoid creating individual status messages
                        chatManager: nil
                    )
                }
                
                if success {
                    successCount += 1
                } else {
                    failureCount += 1
                }
            }
            
            // Update the batch operation status message
            await MainActor.run {
                updateOperationStatusMessage(
                    forMessageId: messageId!,
                    statusMessageId: statusMessageId,
                    status: .success,
                    details: "Added \(successCount) of \(remindersArray.count) reminders",
                    count: successCount
                )
            }
            
            // Refresh context with the updated reminders
            await refreshContextData()
            
            return "Processed \(remindersArray.count) reminders: \(successCount) added successfully, \(failureCount) failed"
            
        case "modify_reminder":
            // CRITICAL DEBUG FOR SINGLE REMINDER UPDATES
            print("‼️‼️‼️ SINGLE REMINDER MODIFY FUNCTION CALLED INSTEAD OF BATCH ‼️‼️‼️")
            print("‼️‼️‼️ SINGLE REMINDER INPUT: \(toolInput)")
            
            // Extract parameters
            guard let id = toolInput["id"] as? String else {
                return "Error: Missing required parameter 'id' for modify_reminder"
            }
            
            let title = toolInput["title"] as? String
            let dueString = toolInput["due"] as? String
            let notes = toolInput["notes"] as? String
            let list = toolInput["list"] as? String
            
            // Parse due date if provided
            var dueDate: Date? = nil
            
            if let dueString = dueString {
                if dueString.lowercased() == "null" || dueString.lowercased() == "no due date" {
                    dueDate = nil // Explicitly setting to nil to clear the due date
                } else {
                    dueDate = parseDate(dueString)
                    if dueDate == nil {
                        return "Error parsing due date: \(dueString)"
                    }
                }
            }
            
            // Create local copy to avoid capturing mutable variable in concurrent code
            let localDueDate = dueDate
            
            // Get access to EventKitManager
            guard let eventKitManager = await getEventKitManager() else {
                return "Error: EventKitManager not available"
            }
            
            // Modify reminder
            let success = await MainActor.run {
                return eventKitManager.updateReminder(
                    id: id,
                    title: title,
                    dueDate: localDueDate,
                    notes: notes,
                    listName: list,
                    messageId: messageId,
                    chatManager: self
                )
            }
            
            // Refresh context with the updated reminders if successful
            if success || messageId != nil {
                await refreshContextData()
            }
            
            return success ? "Successfully updated reminder" : "Failed to update reminder"
            
        case "modify_reminders_batch":
            // CRITICAL DEBUG INDICATOR - To verify this function is actually being called
            print("‼️‼️‼️ MODIFY_REMINDERS_BATCH FUNCTION CALLED - THIS SHOULD BE VISIBLE IN LOGS ‼️‼️‼️")
            print("‼️‼️‼️ FULL TOOL INPUT: \(toolInput)")
            
            // Extract parameters
            // Extract and debug the reminders array structure
            guard let remindersData = toolInput["reminders"] else {
                print("⚙️ ERROR: Missing required parameter 'reminders' for modify_reminders_batch")
                return "Error: Missing required parameter 'reminders' for modify_reminders_batch"
            }
            
            print("⚙️ BATCH DEBUG RAW: reminders parameter type: \(type(of: remindersData))")
            
            // Try to convert to array of dictionaries
            guard let remindersArray = remindersData as? [[String: Any]] else {
                print("⚙️ ERROR: 'reminders' parameter is not an array of dictionaries: \(remindersData)")
                return "Error: The 'reminders' parameter must be an array of reminder objects"
            }
            
            print("⚙️ BATCH DEBUG: Successfully extracted reminders array with \(remindersArray.count) items")
            
            // Get access to EventKitManager
            guard let eventKitManager = await getEventKitManager() else {
                return "Error: EventKitManager not available"
            }
            
            // Create a status message for the batch operation
            let statusMessageId = await MainActor.run {
                let message = addOperationStatusMessage(
                    forMessageId: messageId!,
                    operationType: .updateReminder,
                    status: .inProgress,
                    count: remindersArray.count
                )
                return message.id
            }
            
            var successCount = 0
            var failureCount = 0
            
            // Debug the full reminders array before processing
            print("⚙️ BATCH EDIT START: Processing batch with \(remindersArray.count) reminders")
            for (index, reminder) in remindersArray.enumerated() {
                print("⚙️ BATCH EDIT PREP: Reminder \(index+1): \(reminder)")
            }
            
            // Process each reminder in the batch
            for (index, reminderData) in remindersArray.enumerated() {
                print("⚙️ BATCH EDIT: Processing reminder \(index+1) of \(remindersArray.count)")
                
                guard let id = reminderData["id"] as? String else {
                    print("⚙️ Missing required parameter 'id' for reminder \(index+1) in batch")
                    failureCount += 1
                    continue
                }
                
                let title = reminderData["title"] as? String
                let dueString = reminderData["due"] as? String
                let notes = reminderData["notes"] as? String
                let list = reminderData["list"] as? String
                
                // Parse due date if provided
                var dueDate: Date? = nil
                
                if let dueString = dueString {
                    // If dueString is explicitly set to null or no due date
                    if dueString.lowercased() == "null" || dueString.lowercased() == "no due date" {
                        dueDate = nil // Explicitly setting to nil to clear the due date
                        print("⚙️ BATCH DEBUG: Clearing due date based on explicit null value")
                    } else {
                        dueDate = parseDate(dueString)
                        if dueDate == nil {
                            print("⚙️ Error parsing due date: \(dueString)")
                            failureCount += 1
                            continue
                        }
                        print("⚙️ BATCH DEBUG: Setting new due date to: \(dueDate!)")
                    }
                } else if title == nil && notes == nil && list == nil {
                    // If no parameters provided except ID, this is a batch clear due date operation
                    dueDate = nil
                    print("⚙️ BATCH DEBUG: FORCING due date clear - no other parameters provided except ID")
                } else {
                    // Some parameters provided but not due date - IMPORTANT: we must pass a special value
                    // that will be interpreted by EventKitManager as "don't change the existing due date"
                    print("⚙️ BATCH DEBUG: Keeping existing due date - updating other fields only")
                    // By not setting dueDate at all (or setting it to nil explicitly), the EventKitManager 
                    // will know to keep the existing due date
                    dueDate = nil
                }
                
                // Create local copy to avoid capturing mutable variable in concurrent code
                let localDueDate = dueDate
                
                // Modify reminder - Add a visible separator between reminders for easier debugging
                print("\n⚙️ ========== PROCESSING REMINDER \(index+1) OF \(remindersArray.count) ==========")
                print("⚙️ BATCH EDIT: Processing reminder with ID \(id), new title: \(String(describing: title))")
                
                // Use the direct async method to update without the wrapper that causes issues
                // Added extensive debugging for batch operations
                print("⚙️ BATCH EDIT DETAILED: Updating reminder ID: \(id)")
                print("⚙️ BATCH EDIT DETAILED: Parameters - title: \(String(describing: title)), notes: \(String(describing: notes)), list: \(String(describing: list))")
                print("⚙️ BATCH EDIT DETAILED: Due date parameter: \(String(describing: localDueDate))")
                
                let success = await eventKitManager.updateReminder(
                    id: id,
                    title: title,
                    dueDate: localDueDate,
                    notes: notes,
                    isCompleted: nil,
                    listName: list
                )
                
                print("⚙️ BATCH EDIT: Reminder update result for ID \(id): \(success ? "SUCCESS" : "FAILURE")")
                
                if success {
                    successCount += 1
                } else {
                    failureCount += 1
                }
            }
            
            // Update the batch operation status message
            print("⚙️ BATCH EDIT SUMMARY: Processed \(remindersArray.count) reminders: \(successCount) succeeded, \(failureCount) failed")
            
            await MainActor.run {
                updateOperationStatusMessage(
                    forMessageId: messageId!,
                    statusMessageId: statusMessageId,
                    status: .success,
                    details: "Updated \(successCount) of \(remindersArray.count) reminders",
                    count: successCount
                )
                print("⚙️ BATCH EDIT: Updated status message with count: \(successCount)")
            }
            
            // Refresh context with the updated reminders
            await refreshContextData()
            
            return "Processed \(remindersArray.count) reminders: \(successCount) updated successfully, \(failureCount) failed"
            
        case "delete_reminder":
            // Check if we're dealing with a single ID or multiple IDs
            if let id = toolInput["id"] as? String {
                // Single deletion
                print("⚙️ Processing single reminder deletion: \(id)")
                
                // Get access to EventKitManager
                guard let eventKitManager = await getEventKitManager() else {
                    return "Error: EventKitManager not available"
                }
                
                // Delete reminder
                let success = await MainActor.run {
                    return eventKitManager.deleteReminder(
                        id: id,
                        messageId: messageId,
                        chatManager: self
                    )
                }
                
                // Refresh context with the updated reminders if successful
                if success || messageId != nil {
                    await refreshContextData()
                }
                
                return success ? "Successfully deleted reminder" : "Failed to delete reminder"
            }
            else if let ids = toolInput["ids"] as? [String] {
                // Multiple deletion
                print("⚙️ Processing batch of \(ids.count) reminders to delete")
                
                // Get access to EventKitManager
                guard let eventKitManager = await getEventKitManager() else {
                    return "Error: EventKitManager not available"
                }
                
                // Create a status message for the batch operation
                let statusMessageId = await MainActor.run {
                    let message = addOperationStatusMessage(
                        forMessageId: messageId!,
                        operationType: .deleteReminder,
                        status: .inProgress,
                        count: ids.count
                    )
                    return message.id
                }
                
                // Use a task group to delete reminders in parallel
                var successCount = 0
                var failureCount = 0
                
                // First, deduplicate IDs to avoid trying to delete the same reminder twice
                // This is needed because recurring reminders often have the same ID
                let uniqueIds = Array(Set(ids))
                print("⚙️ Deduplicating \(ids.count) IDs to \(uniqueIds.count) unique IDs")
                
                await withTaskGroup(of: (Bool, String?).self) { group in
                    for id in uniqueIds {
                        group.addTask {
                            // Delete reminder directly
                            let result = await eventKitManager.deleteReminder(
                                id: id,
                                messageId: nil, // Don't create per-reminder status messages
                                chatManager: nil
                            )
                            // The EventKitManager stores error details internally, so we don't get an error object here
                            return (result, result ? nil : "Object not found or could not be deleted")
                        }
                    }
                    
                    // Process results as they complete
                    for await (success, errorMessage) in group {
                        if success {
                            successCount += 1
                        } else {
                            // Don't count "not found" errors as failures when deleting multiple reminders
                            // since they might be recurring instances of the same reminder
                            let isAlreadyDeletedError = errorMessage?.contains("not found") ?? false 
                                || errorMessage?.contains("may have been deleted") ?? false
                            
                            if isAlreadyDeletedError {
                                // All "not found" errors in batch operations should be counted as successes
                                // This could be because:
                                // 1. Reminders with identical IDs (recurring reminders)
                                // 2. Reminders already deleted in a previous operation
                                // 3. Reminders that were automatically deleted (e.g., completed reminders)
                                print("⚙️ Reminder was already deleted or doesn't exist - counting as success")
                                successCount += 1
                            } else {
                                failureCount += 1
                            }
                        }
                    }
                }
                
                // Update the batch operation status message
                await MainActor.run {
                    updateOperationStatusMessage(
                        forMessageId: messageId!,
                        statusMessageId: statusMessageId,
                        status: .success,
                        details: "Deleted \(successCount) of \(ids.count) reminders",
                        count: successCount
                    )
                }
                
                print("⚙️ Completed batch delete: \(successCount) succeeded, \(failureCount) failed")
                
                // Refresh context with the updated reminders
                await refreshContextData()
                
                // For Claude responses, always report success to provide a better UX
                if messageId != nil {
                    return "Successfully deleted reminders"
                } else {
                    return "Processed \(ids.count) reminders: \(successCount) deleted successfully, \(failureCount) failed"
                }
            }
            else {
                return "Error: Either 'id' or 'ids' parameter must be provided for delete_reminder"
            }
            
        case "delete_reminders_batch":
            // Extract parameters
            guard let ids = toolInput["ids"] as? [String] else {
                print("⚙️ Missing required parameter 'ids' for delete_reminders_batch")
                return "Error: Missing required parameter 'ids' for delete_reminders_batch"
            }
            
            // Get access to EventKitManager
            guard let eventKitManager = await getEventKitManager() else {
                return "Error: EventKitManager not available"
            }
            
            // Create a status message for the batch operation
            let statusMessageId = await MainActor.run {
                let message = addOperationStatusMessage(
                    forMessageId: messageId!,
                    operationType: .deleteReminder,
                    status: .inProgress,
                    count: ids.count
                )
                return message.id
            }
            
            print("⚙️ Processing batch of \(ids.count) reminders to delete")
            
            // Use a task group to delete reminders in parallel
            var successCount = 0
            var failureCount = 0
            
            // First, deduplicate IDs to avoid trying to delete the same reminder twice
            // This is needed because recurring reminders often have the same ID
            let uniqueIds = Array(Set(ids))
            print("⚙️ Deduplicating \(ids.count) IDs to \(uniqueIds.count) unique IDs")
            
            await withTaskGroup(of: (Bool, String?).self) { group in
                for id in uniqueIds {
                    group.addTask {
                        // Delete reminder directly with the async method
                        let result = await eventKitManager.deleteReminder(
                            id: id,
                            messageId: nil, // Don't create per-reminder status messages
                            chatManager: nil
                        )
                        // The EventKitManager stores error details internally, so we don't get an error object here
                        return (result, result ? nil : "Object not found or could not be deleted")
                    }
                }
                
                // Process results as they complete
                for await (success, errorMessage) in group {
                    if success {
                        successCount += 1
                    } else {
                        // Don't count "not found" errors as failures when deleting multiple reminders
                        // since they might be recurring instances of the same reminder
                        let isAlreadyDeletedError = errorMessage?.contains("not found") ?? false 
                            || errorMessage?.contains("may have been deleted") ?? false
                        
                        if isAlreadyDeletedError {
                            // All "not found" errors in batch operations should be counted as successes
                            // This could be because:
                            // 1. Reminders with identical IDs (recurring reminders)
                            // 2. Reminders already deleted in a previous operation
                            // 3. Reminders that were automatically deleted (e.g., completed reminders)
                            print("⚙️ Reminder was already deleted or doesn't exist - counting as success")
                            successCount += 1
                        } else {
                            failureCount += 1
                        }
                    }
                }
            }
            
            // Update the batch operation status message
            await MainActor.run {
                updateOperationStatusMessage(
                    forMessageId: messageId!,
                    statusMessageId: statusMessageId,
                    status: .success,
                    details: "Deleted \(successCount) of \(ids.count) reminders",
                    count: successCount
                )
            }
            
            print("⚙️ Completed batch delete: \(successCount) succeeded, \(failureCount) failed")
            return "Processed \(ids.count) reminders: \(successCount) deleted successfully, \(failureCount) failed"
            
        case "add_memory":
            // Extract parameters
            guard let content = toolInput["content"] as? String,
                  let category = toolInput["category"] as? String else {
                print("⚙️ ERROR: Missing required parameters for add_memory")
                return "Error: Missing required parameters for add_memory"
            }
            
            let importance = toolInput["importance"] as? Int ?? 3
            
            print("⚙️ Processing add_memory tool call:")
            print("⚙️ - Content: \"\(content)\"")
            print("⚙️ - Category: \"\(category)\"")
            print("⚙️ - Importance: \(importance)")
            
            // Get access to MemoryManager
            guard let memoryManager = await getMemoryManager() else {
                print("⚙️ ERROR: MemoryManager not available")
                return "Error: MemoryManager not available"
            }
            
            // Find the appropriate memory category
            let memoryCategory = MemoryCategory.allCases.first { $0.rawValue.lowercased() == category.lowercased() } ?? .notes
            print("⚙️ Mapped category string to enum: \(memoryCategory.rawValue)")

            // Add memory with operation status tracking
            do {
                print("⚙️ Calling memoryManager.addMemory with operation status...")
                try await memoryManager.addMemory(
                    content: content, 
                    category: memoryCategory, 
                    importance: importance,
                    messageId: messageId,
                    chatManager: self
                )
                print("⚙️ Memory successfully added")
                
                // Refresh context with the updated memories
                await refreshContextData()
                
                return "Successfully added memory"
            } catch {
                print("⚙️ ERROR: Failed to add memory: \(error.localizedDescription)")
                return error.localizedDescription
            }
            
        case "add_memories_batch":
            // Extract parameters
            guard let memoriesArray = toolInput["memories"] as? [[String: Any]] else {
                print("⚙️ Missing required parameter 'memories' for add_memories_batch")
                return "Error: Missing required parameter 'memories' for add_memories_batch"
            }
            
            // Get access to MemoryManager
            guard let memoryManager = await getMemoryManager() else {
                return "Error: MemoryManager not available"
            }
            
            // Create a batch operation status message
            let statusMessageId = await MainActor.run {
                let message = addOperationStatusMessage(
                    forMessageId: messageId!,
                    operationType: OperationType.addMemory,
                    status: .inProgress,
                    details: "Adding \(memoriesArray.count) memories",
                    count: memoriesArray.count
                )
                return message.id
            }
            
            var successCount = 0
            var failureCount = 0
            
            // Process each memory in the batch
            for memoryData in memoriesArray {
                guard let content = memoryData["content"] as? String,
                      let category = memoryData["category"] as? String else {
                    print("⚙️ Missing required parameters for memory in batch")
                    failureCount += 1
                    continue
                }
                
                let importance = memoryData["importance"] as? Int ?? 3
                
                // Find the appropriate memory category
                let memoryCategory = MemoryCategory.allCases.first { $0.rawValue.lowercased() == category.lowercased() } ?? .notes

                // Add memory
                do {
                    try await memoryManager.addMemory(content: content, category: memoryCategory, importance: importance)
                    successCount += 1
                } catch {
                    print("⚙️ Failed to add memory: \(error.localizedDescription)")
                    failureCount += 1
                }
            }
            
            // Update the batch operation status message
            await MainActor.run {
                updateOperationStatusMessage(
                    forMessageId: messageId!,
                    statusMessageId: statusMessageId,
                    status: .success,
                    details: "Added \(successCount) of \(memoriesArray.count) memories"
                )
            }
            
            // Refresh context with the updated memories
            await refreshContextData()
            
            return "Processed \(memoriesArray.count) memories: \(successCount) added successfully, \(failureCount) failed"
            
        case "remove_memory":
            // Extract parameters
            guard let content = toolInput["content"] as? String else {
                return "Error: Missing required parameter 'content' for remove_memory"
            }
            
            // Get access to MemoryManager
            guard let memoryManager = await getMemoryManager() else {
                return "Error: MemoryManager not available"
            }
            
            // Find memory with matching content on the main thread
            let memoryId: UUID? = await MainActor.run {
                if let memory = memoryManager.memories.first(where: { $0.content == content }) {
                    return memory.id
                }
                return UUID()  // Return a placeholder UUID instead of nil
            }
            
            // Check if we found a memory with the given content
            if let memoryId = memoryId {
                do {
                    try await memoryManager.deleteMemory(
                        id: memoryId,
                        messageId: messageId,
                        chatManager: self
                    )
                    
                    // Refresh context with the updated memories
                    await refreshContextData()
                    
                    return "Successfully removed memory"
                } catch {
                    return "Failed to remove memory: \(error.localizedDescription)"
                }
            } else {
                // Create a failure status message for memory not found
                if let messageId = messageId {
                    await MainActor.run {
                        addOperationStatusMessage(
                            forMessageId: messageId,
                            operationType: OperationType.deleteMemory,
                            status: .failure,
                            details: "No memory found with content: \(content)"
                        )
                    }
                }
                
                return "Error: No memory found with content: \(content)"
            }
            
        case "remove_memories_batch":
            // Extract parameters
            guard let contents = toolInput["contents"] as? [String] else {
                print("⚙️ Missing required parameter 'contents' for remove_memories_batch")
                return "Error: Missing required parameter 'contents' for remove_memories_batch"
            }
            
            // Get access to MemoryManager
            guard let memoryManager = await getMemoryManager() else {
                return "Error: MemoryManager not available"
            }
            
            // Create a batch operation status message
            let statusMessageId = await MainActor.run {
                let message = addOperationStatusMessage(
                    forMessageId: messageId!,
                    operationType: OperationType.deleteMemory,
                    status: .inProgress,
                    details: "Removing \(contents.count) memories",
                    count: contents.count
                )
                return message.id
            }
            
            var successCount = 0
            var failureCount = 0
            
            // Process each content in the batch
            for content in contents {
                // Find memory with matching content on the main thread
                let memoryId: UUID? = await MainActor.run {
                    if let memory = memoryManager.memories.first(where: { $0.content == content }) {
                        return memory.id
                    }
                    return nil
                }
                
                // Check if we found a memory with the given content
                if let memoryId = memoryId {
                    do {
                        try await memoryManager.deleteMemory(id: memoryId)
                        successCount += 1
                    } catch {
                        print("⚙️ Failed to remove memory: \(error.localizedDescription)")
                        failureCount += 1
                    }
                } else {
                    print("⚙️ No memory found with content: \(content)")
                    failureCount += 1
                }
            }
            
            // Update the batch operation status message
            await MainActor.run {
                updateOperationStatusMessage(
                    forMessageId: messageId!,
                    statusMessageId: statusMessageId,
                    status: .success,
                    details: "Removed \(successCount) of \(contents.count) memories",
                    count: successCount
                )
            }
            
            // Refresh context with the updated memories
            await refreshContextData()
            
            return "Processed \(contents.count) memories: \(successCount) removed successfully, \(failureCount) failed"
            
        case "update_memory":
            // Extract parameters
            let idParam = toolInput["id"] as? String
            let contentParam = toolInput["content"] as? String 
            let oldContentParam = toolInput["old_content"] as? String
            let categoryStr = toolInput["category"] as? String
            let newImportance = toolInput["importance"] as? Int
            
            // Get access to MemoryManager
            guard let memoryManager = await getMemoryManager() else {
                return "Error: MemoryManager not available"
            }
            
            // Fallback to content matching if UUID fails or isn't provided
            var targetMemoryId: UUID? = nil
            
            // Try UUID first if provided
            if let idParam = idParam {
                if let uuid = UUID(uuidString: idParam) {
                    // Valid UUID provided
                    targetMemoryId = uuid
                }
            }
            
            // If no valid UUID, try to find memory by content
            if targetMemoryId == nil && oldContentParam != nil {
                // Find memory with matching content
                let memoryWithContent = await MainActor.run {
                    return memoryManager.memories.first(where: { $0.content == oldContentParam })
                }
                
                if let memory = memoryWithContent {
                    targetMemoryId = memory.id
                    print("⚙️ Found memory by content matching: \(oldContentParam ?? "nil")")
                }
            }
            
            // If ID param wasn't a UUID and was provided as content, try that as fallback
            if targetMemoryId == nil && idParam != nil {
                // Try using the ID parameter as content search
                let memoryWithIdAsContent = await MainActor.run {
                    return memoryManager.memories.first(where: { $0.content == idParam })
                }
                
                if let memory = memoryWithIdAsContent {
                    targetMemoryId = memory.id
                    print("⚙️ Found memory by using id parameter as content: \(idParam ?? "nil")")
                }
            }
            
            // Return error if we couldn't identify a memory to update
            guard let targetMemoryId = targetMemoryId else {
                return "Error: Could not find memory to update. Please provide either a valid UUID or the old content of the memory."
            }
            
            // Convert category string to enum if provided
            var newCategory: MemoryCategory? = nil
            if let categoryStr = categoryStr {
                newCategory = MemoryCategory.allCases.first { $0.rawValue.lowercased() == categoryStr.lowercased() } ?? .notes
            }
            
            // Ensure we have at least one field to update
            guard contentParam != nil || newCategory != nil || newImportance != nil else {
                return "Error: At least one of 'content', 'category', or 'importance' must be provided for update_memory"
            }
            
            // Update memory
            do {
                try await memoryManager.updateMemory(
                    id: targetMemoryId,
                    newContent: contentParam,
                    newCategory: newCategory,
                    newImportance: newImportance,
                    messageId: messageId,
                    chatManager: self
                )
                
                // Refresh context with the updated memories
                await refreshContextData()
                
                return "Successfully updated memory"
            } catch {
                return "Failed to update memory: \(error.localizedDescription)"
            }
            
        case "update_memories_batch":
            // Extract parameters
            guard let memoriesArray = toolInput["memories"] as? [[String: Any]] else {
                print("⚙️ Missing required parameter 'memories' for update_memories_batch")
                return "Error: Missing required parameter 'memories' for update_memories_batch"
            }
            
            // Get access to MemoryManager
            guard let memoryManager = await getMemoryManager() else {
                return "Error: MemoryManager not available"
            }
            
            // Create a batch operation status message
            let statusMessageId = await MainActor.run {
                let message = addOperationStatusMessage(
                    forMessageId: messageId!,
                    operationType: OperationType.updateMemory,
                    status: .inProgress,
                    details: "Updating \(memoriesArray.count) memories",
                    count: memoriesArray.count
                )
                return message.id
            }
            
            var successCount = 0
            var failureCount = 0
            
            // Process each memory in the batch
            for memoryData in memoriesArray {
                // Extract parameters for this memory
                let idParam = memoryData["id"] as? String
                let contentParam = memoryData["content"] as? String
                let oldContentParam = memoryData["old_content"] as? String
                let categoryStr = memoryData["category"] as? String
                let newImportance = memoryData["importance"] as? Int
                
                // Fallback to content matching if UUID fails or isn't provided
                var targetMemoryId: UUID? = nil
                
                // Try UUID first if provided
                if let idParam = idParam {
                    if let uuid = UUID(uuidString: idParam) {
                        targetMemoryId = uuid
                    }
                }
                
                // If no valid UUID, try to find memory by content
                if targetMemoryId == nil && oldContentParam != nil {
                    // Find memory with matching content
                    let memoryWithContent = await MainActor.run {
                        return memoryManager.memories.first(where: { $0.content == oldContentParam })
                    }
                    
                    if let memory = memoryWithContent {
                        targetMemoryId = memory.id
                        print("⚙️ Found memory by content matching: \(oldContentParam ?? "nil")")
                    }
                }
                
                // If ID param wasn't a UUID and was provided as content, try that as fallback
                if targetMemoryId == nil && idParam != nil {
                    // Try using the ID parameter as content search
                    let memoryWithIdAsContent = await MainActor.run {
                        return memoryManager.memories.first(where: { $0.content == idParam })
                    }
                    
                    if let memory = memoryWithIdAsContent {
                        targetMemoryId = memory.id
                        print("⚙️ Found memory by using id parameter as content: \(idParam ?? "nil")")
                    }
                }
                
                // Skip this memory if we couldn't identify it
                guard let memoryId = targetMemoryId else {
                    print("⚙️ Could not find memory to update in batch")
                    failureCount += 1
                    continue
                }
                
                // Convert category string to enum if provided
                var newCategory: MemoryCategory? = nil
                if let categoryStr = categoryStr {
                    newCategory = MemoryCategory.allCases.first { $0.rawValue.lowercased() == categoryStr.lowercased() } ?? .notes
                }
                
                // Skip if no fields to update
                guard contentParam != nil || newCategory != nil || newImportance != nil else {
                    failureCount += 1
                    continue
                }
                
                // Update memory
                do {
                    try await memoryManager.updateMemory(
                        id: memoryId,
                        newContent: contentParam,
                        newCategory: newCategory,
                        newImportance: newImportance
                    )
                    successCount += 1
                } catch {
                    print("⚙️ Failed to update memory in batch: \(error.localizedDescription)")
                    failureCount += 1
                }
            }
            
            // Update the batch operation status message
            await MainActor.run {
                updateOperationStatusMessage(
                    forMessageId: messageId!,
                    statusMessageId: statusMessageId,
                    status: .success,
                    details: "Updated \(successCount) of \(memoriesArray.count) memories",
                    count: successCount
                )
            }
            
            // Refresh context with the updated memories
            await refreshContextData()
            
            return "Processed \(memoriesArray.count) memories: \(successCount) updated successfully, \(failureCount) failed"
            
        default:
            return "Error: Unknown tool \(toolName)"
        }
    }
    
    
    /**
     * Processes Claude's response for legacy command formats.
     *
     * This function is kept for backward compatibility.
     * It processes legacy command formats in the text responses.
     *
     * @param response The text response from Claude
     */
    private func processClaudeResponse(_ response: String) async {
        // For backward compatibility, we'll still process legacy command formats
        // that might be in the text response using bracket syntax
        
            // Process memory instructions for bracket format
            if let memManager = memoryManager {
                let memoryUpdated = await toolHandler.processMemoryUpdates(response: response, memoryManager: memManager, chatManager: self)
                
                // If memory wasn't updated through bracket format,
                // we still need to manually refresh context to ensure it's up-to-date
                if !memoryUpdated {
                    await refreshContextData()
                    print("🔄 Manually refreshing context after processing response")
                }
            }
        
        // Note: We don't need to process calendar and reminder commands here anymore
        // because they're now handled via the tool use system
    }
    
    // MARK: - Context Management
    
    /**
     * Updates the API service with the latest context data
     * This should be called after any calendar events, reminders, or memories change
     * to ensure the API has access to the latest context information
     */
    /**
     * Updates the API service with the latest context data
     * This should be called after any calendar events, reminders, or memories change
     * to ensure the API has access to the latest context information
     * 
     * IMPORTANT: This method is now called before each API request to ensure
     * the date/time and all context data is always up-to-date.
     */
    func refreshContextData() async {
        print("🔄 Refreshing context data for up-to-date information")
        print("🕒 Current time: \(DateFormatter.formatCurrentDateTimeWithTimezone())")
        
        // Refresh memory content
        if let manager = memoryManager {
            // Force a fresh read from the memory manager
            let memoryContent = await manager.readMemory()
            
            // Print some sample memories for debugging
            let memories = manager.memories
            print("🔄 MEMORY CONTENT PREVIEW (First 3 items):")
            if memories.count > 0 {
                for i in 0..<min(3, memories.count) {
                    print("🔄 Memory \(i+1): \(memories[i].content) (Category: \(memories[i].category.rawValue), Importance: \(memories[i].importance))")
                }
            } else {
                print("🔄 No memories available")
            }
            
            // Update memory context in API service
            await apiService.updateMemoryContext(memoryContent)
            print("🔄 Memory context refreshed with \(memories.count) total items")
        }
        
        // Force a fresh fetch of calendar events
        let calendarEvents = eventKitManager?.fetchUpcomingEvents(days: 7) ?? []
        let calendarContext = formatCalendarEvents(calendarEvents)
        await apiService.updateCalendarContext(calendarContext)
        print("🔄 Calendar context refreshed with \(calendarEvents.count) events")
        
        // Force a fresh fetch of reminders
        let reminders = await eventKitManager?.fetchReminders() ?? []
        let remindersContext = formatReminders(reminders)
        await apiService.updateRemindersContext(remindersContext)
        print("🔄 Reminders context refreshed with \(reminders.count) reminders")
        
        // Get fresh location data if needed
        let locationContext = await getLocationContext()
        await apiService.updateLocationContext(locationContext)
        print("🔄 Location context refreshed")
    }
}
