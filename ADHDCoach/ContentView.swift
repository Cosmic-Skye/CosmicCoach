import SwiftUI
import Combine

struct ContentView: View {
    @EnvironmentObject private var chatManager: ChatManager
    @EnvironmentObject private var eventKitManager: EventKitManager
    @EnvironmentObject private var memoryManager: MemoryManager
    @State private var messageText = ""
    @FocusState private var isInputFocused: Bool
    @State private var showingSettings = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var scrollToBottom = false
    @AppStorage("hasAppearedBefore") private var hasAppearedBefore = false
    @Environment(\.scenePhase) private var scenePhase
    
    // Add observer for chat history deletion
    init() {
        // This is needed because @EnvironmentObject isn't available in init
        print("⏱️ ContentView initializing")
    }
    
    // Helper function to scroll to bottom of chat
    private func scrollToBottom(proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation {
                proxy.scrollTo("bottomID", anchor: .bottom)
            }
        }
    }
    
    // Helper function to reset chat when notification is received
    private func setupNotificationObserver() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ChatHistoryDeleted"),
            object: nil,
            queue: .main
        ) { [self] _ in
            // This will be called when chat history is deleted
            chatManager.messages = []
            
            // Instead of static welcome message, try to do a preemptive query
            Task {
                // Try sending automatic message after chat history deletion
                await chatManager.checkAndSendAutomaticMessageAfterHistoryDeletion()
            }
        }
        
        // Set up keyboard notifications
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                keyboardHeight = keyboardFrame.height
                scrollToBottom = true
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { _ in
            keyboardHeight = 0
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    // Chat messages list
                    ScrollViewReader { proxy in
                        ScrollView {
                            if chatManager.messages.isEmpty {
                                // Empty state with a centered welcome message
                                VStack {
                                    Spacer()
                                    Text("Welcome to Cosmic Coach")
                                        .font(.headline)
                                        .foregroundColor(.secondary)
                                    Text("Type a message to get started")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .frame(maxHeight: .infinity)
                            } else {
                                LazyVStack(spacing: 12) {
                                    ForEach(chatManager.messages) { message in
                                        VStack(spacing: 4) {
                                            MessageBubbleView(message: message)
                                                .padding(.horizontal)
                                            
                                            // If this is the message that triggered an operation,
                                            // display the operation status message right after it
                                            if !message.isUser && message.isComplete {
                                                // Use the helper method to get status messages for this message
                                                ForEach(chatManager.statusMessagesForMessage(message)) { statusMessage in
                                                    OperationStatusView(statusMessage: statusMessage)
                                                        .padding(.horizontal)
                                                }
                                            }
                                        }
                                    }
                                    
                                    // Invisible spacer view at the end for scrolling
                                    Color.clear
                                        .frame(height: 1)
                                        .id("bottomID")
                                }
                                .padding(.vertical, 8)
                            }
                        }
                        .onChange(of: chatManager.messages.count) { _, _ in
                            scrollToBottom(proxy: proxy)
                        }
                        .onChange(of: chatManager.streamingUpdateCount) { _, _ in
                            scrollToBottom(proxy: proxy)
                        }
                        .onChange(of: scrollToBottom) { _, newValue in
                            if newValue {
                                scrollToBottom(proxy: proxy)
                                scrollToBottom = false
                            }
                        }
                        .onAppear {
                            // Scroll to bottom on first appear
                            scrollToBottom(proxy: proxy)
                        }
                    }
                
                    // Input area
                    HStack {
                        TextField("Message", text: $messageText)
                            .padding(10)
                            .background(Color(.systemGray6))
                            .cornerRadius(20)
                            .focused($isInputFocused)
                        
                        Button(action: sendMessage) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 30))
                                .foregroundColor(.blue)
                        }
                        .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatManager.isProcessing)
                    }
                    .padding()
                }
                .animation(.easeOut(duration: 0.16), value: keyboardHeight)
            }
            .navigationTitle("Cosmic Coach")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        showingSettings = true
                    }) {
                        Image(systemName: "gear")
                            .font(.system(size: 22))
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .onAppear {
                print("⏱️ ContentView.onAppear - START")
                // Connect the memory manager to the chat manager
                chatManager.setMemoryManager(memoryManager)
                print("⏱️ ContentView.onAppear - Connected memory manager to chat manager")
                
                // Setup notification observer for chat history deletion
                setupNotificationObserver()
                print("⏱️ ContentView.onAppear - Set up notification observer")
                
                // Check if automatic messages should be enabled in settings and log it
                let automaticMessagesEnabled = UserDefaults.standard.bool(forKey: "enable_automatic_responses")
                print("⏱️ ContentView.onAppear - Automatic messages enabled in settings: \(automaticMessagesEnabled)")
                
                // Only check for automatic messages if we have appeared before
                // This ensures we don't trigger on the initial app launch/init
                if hasAppearedBefore {
                    print("⏱️ ContentView.onAppear - This is a RE-APPEARANCE (hasAppearedBefore=true), likely from background")
                    
                    // Ensure memory is properly loaded
                    Task {
                        print("⏱️ ContentView.onAppear - Task started for memory loading and automatic message")
                        await memoryManager.loadMemory()
                        if let fileURL = memoryManager.getMemoryFileURL() {
                            print("⏱️ ContentView.onAppear - Memory file exists: \(FileManager.default.fileExists(atPath: fileURL.path))")
                            print("⏱️ ContentView.onAppear - Memory content length: \(memoryManager.memoryContent.count)")
                        }
                        
                        // Log automatic message check
                        print("⏱️ ContentView.onAppear - About to check for automatic message")
                        
                        // Prepare to send automatic message
                        print("⏱️ ContentView.onAppear - Preparing automatic message check")
                        
                        // Check and potentially send an automatic message
                        print("⏱️ ContentView.onAppear - About to call checkAndSendAutomaticMessage() at \(Date())")
                        await chatManager.checkAndSendAutomaticMessage()
                        print("⏱️ ContentView.onAppear - Returned from checkAndSendAutomaticMessage() at \(Date())")
                    }
                } else {
                    print("⏱️ ContentView.onAppear - This is the FIRST appearance (hasAppearedBefore=false), setting to true")
                    // Just load memory but don't check for automatic messages on first appearance
                    Task {
                        await memoryManager.loadMemory()
                        if let fileURL = memoryManager.getMemoryFileURL() {
                            print("⏱️ ContentView.onAppear - Memory file exists: \(FileManager.default.fileExists(atPath: fileURL.path))")
                            print("⏱️ ContentView.onAppear - Memory content length: \(memoryManager.memoryContent.count)")
                        }
                    }
                    // Mark that we've appeared before for next time
                    hasAppearedBefore = true
                    print("⏱️ ContentView.onAppear - Set hasAppearedBefore to TRUE in AppStorage")
                }
                print("⏱️ ContentView.onAppear - END (task continues asynchronously)")
            }
            .task {
                // This is a different lifecycle event than onAppear
                print("⏱️ ContentView.task - Running")
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                print("⏱️ ContentView.onChange(scenePhase) - \(oldPhase) -> \(newPhase)")
                
                // Check for transition to active state (from any state)
                if newPhase == .active {
                    print("⏱️ ContentView.onChange - App becoming active")
                    
                    // Only run the automatic message check if we've seen the app before
                    if hasAppearedBefore {
                        // Check for last session time
                        if let lastSessionTime = UserDefaults.standard.object(forKey: "last_app_session_time") as? TimeInterval {
                            let lastTime = Date(timeIntervalSince1970: lastSessionTime)
                            let timeSinceLastSession = Date().timeIntervalSince(lastTime)
                            print("⏱️ ContentView.onChange - Last session time: \(lastTime)")
                            print("⏱️ ContentView.onChange - Time since last session: \(timeSinceLastSession) seconds")
                            
                            // Launch a task to check for automatic messages
                            // This is critical because the normal onAppear doesn't seem to be firing consistently
                            Task {
                                print("⏱️ ContentView.onChange - Starting task for automatic message check at \(Date())")
                                await memoryManager.loadMemory()
                                
                                // Check and potentially send an automatic message
                                await chatManager.checkAndSendAutomaticMessage()
                                print("⏱️ ContentView.onChange - Completed automatic message check at \(Date())")
                            }
                        }
                    } else {
                        print("⏱️ ContentView.onChange - Not checking automatic messages, hasAppearedBefore = false")
                    }
                }
            }
        }
    }
    
    private func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        let trimmedMessage = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        messageText = ""
        
        // Add user message to chat
        chatManager.addUserMessage(content: trimmedMessage)
        
        // Send to Claude API
        Task {
            // Get context from EventKit
            let calendarEvents = eventKitManager.fetchUpcomingEvents(days: 7)
            let reminders = await eventKitManager.fetchReminders()
            
            await chatManager.sendMessageToClaude(
                userMessage: trimmedMessage,
                calendarEvents: calendarEvents,
                reminders: reminders
            )
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(ChatManager())
        .environmentObject(EventKitManager())
        .environmentObject(MemoryManager())
}
