import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
// import 'package:http/http.dart' as http;
// import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:careconnect/services/local_storage_service.dart';

class ChatScreen extends StatefulWidget {
  final Map<String, dynamic> doctor;
  final String? existingChatRoomId;

  const ChatScreen({
    super.key,
    required this.doctor,
    this.existingChatRoomId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  List<Map<String, dynamic>> messages = [];
  bool isLoading = true;
  String error = '';
  Stream<QuerySnapshot>? _messagesStream;
  String? _chatRoomId;
  String? _authToken;
  String? _editingMessageId;
  bool _isEditing = false;
  String? _chatSendId;
  String? _senderName;

  // ChatService._internal() {
  //   _initializeUserRole();
  // }

  Future<void> _getStoredToken() async {
    try {
      _authToken = await LocalStorageService.getAuthToken();
      print(
          'Retrieved stored token: ${_authToken != null ? 'Token exists' : 'No token found'}');
    } catch (e) {
      print('Error getting stored token: $e');
    }
  }

  Future<void> _initializeUserRole() async {
    try {
      _chatSendId = await LocalStorageService.getUserId();
      _senderName = await LocalStorageService.getUserName();

      print('User ID from storage: $_chatSendId');
      if (_chatSendId == null) {
        setState(() {
          error = 'Failed to get user ID';
          isLoading = false;
        });
      }
    } catch (e) {
      print('Error getting user ID: $e');
      setState(() {
        error = 'Error initializing user ID: $e';
        isLoading = false;
      });
    }
  }

  Future<void> _storeToken(String token) async {
    try {
      await LocalStorageService.saveAuthData(
        token: token,
        userData: {'token': token},
      );
      _authToken = token;
      print('Token stored successfully');
    } catch (e) {
      print('Error storing token: $e');
    }
  }

  @override
  void initState() {
    super.initState();

    print('ChatScreen initialized with doctor ID: ${widget.doctor['userId']}');
    _initializeUserRole().then((_) {
      print('User role initialized with ID: $_chatSendId');
      _initializeChat();
    });
  }

  // Add this method to check if we need to migrate messages
  Future<void> _checkAndMigrateChatRooms() async {
    try {
      if (_chatSendId == null) return;

      print('Checking for chat rooms to migrate...');

      // Search for all chat rooms where the user is a participant
      final userChatsQuery = await _firestore
          .collection('chatRooms')
          .where('participants', arrayContains: _chatSendId)
          .get();

      // Check for chat rooms with the doctor
      List<DocumentSnapshot> roomsWithDoctor = [];
      for (var doc in userChatsQuery.docs) {
        final data = doc.data();
        if (data['participants'] != null &&
            (data['participants'] as List).contains(widget.doctor['userId'])) {
          roomsWithDoctor.add(doc);
        }
      }

      // If we found multiple chat rooms with the same doctor, we need to merge them
      if (roomsWithDoctor.length > 1) {
        print(
            'Found ${roomsWithDoctor.length} chat rooms with the same doctor. Need to merge.');

        // Sort rooms by message count or creation time to find the primary one
        final List<Map<String, dynamic>> roomsWithCounts = [];

        for (var doc in roomsWithDoctor) {
          final messagesQuery = await _firestore
              .collection('chatRooms')
              .doc(doc.id)
              .collection('messages')
              .get();

          roomsWithCounts.add({
            'roomId': doc.id,
            'messageCount': messagesQuery.docs.length,
            'data': doc.data(),
          });
        }

        // Sort by message count (descending)
        roomsWithCounts.sort((a, b) => b['messageCount'] - a['messageCount']);

        // Select the room with the most messages as our primary
        final primaryRoom = roomsWithCounts.first;
        print(
            'Selected primary room: ${primaryRoom['roomId']} with ${primaryRoom['messageCount']} messages');

        // Generate the consistent chat room ID
        List<String> ids = [widget.doctor['userId'], _chatSendId!];
        ids.sort();
        final consistentId = '${ids[0]}_${ids[1]}';

        // If the primary room is not the consistent room, we need to create/update the consistent room
        if (primaryRoom['roomId'] != consistentId) {
          print(
              'Primary room ID does not match consistent ID. Will migrate to: $consistentId');

          // Create the consistent room if it doesn't exist
          final consistentRoomDoc =
              await _firestore.collection('chatRooms').doc(consistentId).get();
          if (!consistentRoomDoc.exists) {
            await _firestore.collection('chatRooms').doc(consistentId).set({
              'participants': [_chatSendId, widget.doctor['userId']],
              'lastMessage': primaryRoom['data']['lastMessage'] ?? '',
              'lastMessageTime': primaryRoom['data']['lastMessageTime'] ??
                  FieldValue.serverTimestamp(),
              'lastMessageSender':
                  primaryRoom['data']['lastMessageSender'] ?? _chatSendId,
              'lastMessageSenderName': primaryRoom['data']
                      ['lastMessageSenderName'] ??
                  _senderName ??
                  'User',
              'status': 'active',
              'unreadCount': 0,
              'createdAt': FieldValue.serverTimestamp(),
              'updatedAt': FieldValue.serverTimestamp(),
              'migratedFrom': roomsWithDoctor.map((doc) => doc.id).toList(),
            });
            print('Created consistent chat room');
          }

          // Migrate messages from all rooms to the consistent room
          int migratedCount = 0;
          for (var room in roomsWithCounts) {
            if (room['roomId'] == consistentId) continue;

            final messagesQuery = await _firestore
                .collection('chatRooms')
                .doc(room['roomId'])
                .collection('messages')
                .get();

            for (var msgDoc in messagesQuery.docs) {
              final msgData = msgDoc.data();
              await _firestore
                  .collection('chatRooms')
                  .doc(consistentId)
                  .collection('messages')
                  .add(msgData);
              migratedCount++;
            }

            // Add a system message noting the migration
            await _firestore
                .collection('chatRooms')
                .doc(consistentId)
                .collection('messages')
                .add({
              'text': 'Chat history migrated from another conversation',
              'senderId': 'system',
              'senderName': 'System',
              'timestamp': FieldValue.serverTimestamp(),
              'isAdmin': true,
              'type': 'system',
              'status': 'sent',
              'createdAt': FieldValue.serverTimestamp(),
              'updatedAt': FieldValue.serverTimestamp(),
            });

            // Mark the old room as migrated
            await _firestore
                .collection('chatRooms')
                .doc(room['roomId'])
                .update({
              'status': 'migrated',
              'migratedTo': consistentId,
              'updatedAt': FieldValue.serverTimestamp(),
            });
          }

          print('Migrated $migratedCount messages to consistent chat room');

          // Update local chat room ID
          _chatRoomId = consistentId;
          await LocalStorageService.saveChatRoomId(
              widget.doctor['userId'], consistentId);

          // Update the message stream
          _messagesStream = _firestore
              .collection('chatRooms')
              .doc(_chatRoomId)
              .collection('messages')
              .orderBy('timestamp', descending: true)
              .snapshots();

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Chat history has been synchronized'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      print('Error checking for chat rooms to migrate: $e');
    }
  }

  Future<void> _initializeChat() async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        // Try to get stored token
        await _getStoredToken();
        if (_authToken == null) {
          setState(() {
            error = 'Please login to view messages';
            isLoading = false;
          });
          return;
        }
      } else {
        // Get new token and store it
        final token = await user.getIdToken();
        if (token != null) {
          await _storeToken(token);
        } else {
          setState(() {
            error = 'Failed to get authentication token';
            isLoading = false;
          });
          return;
        }
      }

      // Ensure we have either a token or user ID
      final String identifier = _chatSendId ?? _authToken ?? user?.uid ?? '';
      if (identifier.isEmpty) {
        setState(() {
          error = 'No valid user identifier found';
          isLoading = false;
        });
        return;
      }

      // Use existingChatRoomId if provided, otherwise generate one
      if (widget.existingChatRoomId != null) {
        _chatRoomId = widget.existingChatRoomId;
        print('Using provided chat room ID: $_chatRoomId');
      } else {
        _chatRoomId = await _getOrCreateConsistentChatRoomId();
        print('Using generated chat room ID: $_chatRoomId');
      }

      // ADDED: Check and migrate chat rooms if necessary
      await _checkAndMigrateChatRooms();

      // Set up real-time listener for messages with proper ordering and persistence
      _messagesStream = _firestore
          .collection('chatRooms')
          .doc(_chatRoomId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .snapshots();

      // Create chat room if it doesn't exist
      final chatRoomDoc =
          await _firestore.collection('chatRooms').doc(_chatRoomId).get();
      if (!chatRoomDoc.exists) {
        print('Creating new chat room...');
        await _firestore.collection('chatRooms').doc(_chatRoomId).set({
          'participants': [identifier, widget.doctor['userId']],
          'lastMessage': '',
          'lastMessageTime': FieldValue.serverTimestamp(),
          'lastMessageSender': identifier,
          'lastMessageSenderName': user?.displayName ?? 'User',
          'status': 'active',
          'unreadCount': 0,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        print('Chat room created successfully');
      } else {
        // Update last seen timestamp and ensure chat room is active
        await _firestore.collection('chatRooms').doc(_chatRoomId).update({
          'updatedAt': FieldValue.serverTimestamp(),
          'status': 'active',
        });
      }

      // After initialization, immediately fetch messages to ensure we have them
      final messages = await fetchAllMessages();
      print('Initialized with ${messages.length} messages from history');

      setState(() {
        isLoading = false;
        error = '';
      });
    } catch (e) {
      print('Error initializing chat: $e');
      setState(() {
        error = 'Failed to connect to chat: $e';
        isLoading = false;
      });
    }
  }

  Future<void> sendMessage() async {
    if (_messageController.text.trim().isEmpty) return;

    String messageText = _messageController.text.trim();
    try {
      final user = _auth.currentUser;
      if (user == null && _authToken == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please login to send messages'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      if (_chatRoomId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Chat room not initialized'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      // Get the sender ID, using multiple fallback options
      String? senderId = _chatSendId;
      if (senderId == null) {
        senderId = user?.uid;
      }
      if (senderId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to identify sender'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      _messageController.clear(); // Clear the input field immediately

      // Get user details
      String userName = _senderName ?? 'User';
      if (user != null && userName == 'User') {
        final userDoc =
            await _firestore.collection('users').doc(user.uid).get();
        userName = userDoc.exists
            ? (userDoc.data()?['name'] ?? user.displayName ?? 'User')
            : (user.displayName ?? 'User');
      }

      // Verify the chat room exists before proceeding
      final chatRoomDoc =
          await _firestore.collection('chatRooms').doc(_chatRoomId).get();
      if (!chatRoomDoc.exists) {
        print('Chat room does not exist. Recreating...');
        // Create chat room if it doesn't exist
        await _firestore.collection('chatRooms').doc(_chatRoomId).set({
          'participants': [senderId, widget.doctor['userId']],
          'lastMessage': '',
          'lastMessageTime': FieldValue.serverTimestamp(),
          'lastMessageSender': senderId,
          'lastMessageSenderName': userName,
          'status': 'active',
          'unreadCount': 0,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        print('Chat room recreated successfully');
      }

      final timestamp = FieldValue.serverTimestamp();
      final message = {
        'text': messageText,
        'senderId': senderId,
        'receiverId': widget.doctor['userId'],
        'senderName': userName,
        'timestamp': timestamp,
        'isAdmin': false,
        'type': 'text',
        'status': 'sent',
        'createdAt': timestamp,
        'updatedAt': timestamp,
      };

      print('Sending message: $message');

      // Add message to messages collection
      final messageRef = await _firestore
          .collection('chatRooms')
          .doc(_chatRoomId)
          .collection('messages')
          .add(message);

      // Update chat room with last message
      await _firestore.collection('chatRooms').doc(_chatRoomId).update({
        'lastMessage': messageText,
        'lastMessageTime': timestamp,
        'lastMessageSender': senderId,
        'lastMessageSenderName': userName,
        'status': 'active',
        'unreadCount': FieldValue.increment(1),
        'updatedAt': timestamp,
      });

      print('Message sent successfully with ID: ${messageRef.id}');
    } catch (e) {
      print('Error sending message: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to send message: $e'),
          backgroundColor: Colors.red,
        ),
      );
      // Restore the message text if sending failed
      _messageController.text = messageText;
    }
  }

  Future<void> _deleteMessage(String messageId) async {
    try {
      if (_chatRoomId == null) return;
      // Update last message if needed
      final timestamp = FieldValue.serverTimestamp();

      // Delete the message
      await _firestore
          .collection('chatRooms')
          .doc(_chatRoomId)
          .collection('messages')
          .doc(messageId)
          .delete();
      print('Message deleted: $messageId');

      // Check if we need to update the last message in the chat room
      final messagesSnapshot = await _firestore
          .collection('chatRooms')
          .doc(_chatRoomId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .limit(1)
          .get();
      if (messagesSnapshot.docs.isNotEmpty) {
        final lastMessage = messagesSnapshot.docs.first.data();
        await _firestore.collection('chatRooms').doc(_chatRoomId).update({
          'lastMessage': lastMessage['text'],
          'lastMessageTime': lastMessage['timestamp'],
          'lastMessageSender': lastMessage['senderId'],
          'lastMessageSenderName': lastMessage['senderName'],
          'updatedAt': timestamp,
        });
      } else {
        // If no messages left, clear the last message
        await _firestore.collection('chatRooms').doc(_chatRoomId).update({
          'lastMessage': '',
          'lastMessageTime': timestamp,
          'lastMessageSender': null,
          'lastMessageSenderName': null,
          'updatedAt': timestamp,
        });
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Message deleted'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      print('Error deleting message: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to delete message: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _startEditing(String messageId, String currentText) async {
    setState(() {
      _editingMessageId = messageId;
      _isEditing = true;
      _messageController.text = currentText;
    });
  }

  Future<void> _updateMessage() async {
    if (_messageController.text.trim().isEmpty ||
        _editingMessageId == null ||
        _chatRoomId == null) return;

    try {
      final messageText = _messageController.text.trim();
      final timestamp = FieldValue.serverTimestamp();

      // Update the message
      await _firestore
          .collection('chatRooms')
          .doc(_chatRoomId)
          .collection('messages')
          .doc(_editingMessageId)
          .update({
        'text': messageText,
        'isEdited': true,
        'editedAt': timestamp,
        'updatedAt': timestamp,
      });

      // Update last message if this was the last message
      final messageDoc = await _firestore
          .collection('chatRooms')
          .doc(_chatRoomId)
          .collection('messages')
          .doc(_editingMessageId)
          .get();
      if (messageDoc.exists) {
        final messageData = messageDoc.data()!;
        final lastMessageDoc = await _firestore
            .collection('chatRooms')
            .doc(_chatRoomId)
            .collection('messages')
            .orderBy('timestamp', descending: true)
            .limit(1)
            .get();
        if (lastMessageDoc.docs.isNotEmpty &&
            lastMessageDoc.docs.first.id == _editingMessageId) {
          await _firestore.collection('chatRooms').doc(_chatRoomId).update({
            'lastMessage': messageText,
            'updatedAt': timestamp,
          });
        }
      }

      setState(() {
        _editingMessageId = null;
        _isEditing = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Message updated'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      print('Error updating message: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to update message: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // Add the missing cancelEditing method
  void _cancelEditing() {
    setState(() {
      _editingMessageId = null;
      _isEditing = false;
      _messageController.clear();
    });
  }

  Future<String> _getOrCreateConsistentChatRoomId() async {
    // Try to get the stored chat room ID first
    final storedChatRoomId =
        await LocalStorageService.getChatRoomId(widget.doctor['userId']);
    if (storedChatRoomId != null && storedChatRoomId.isNotEmpty) {
      print('Using stored chat room ID: $storedChatRoomId');

      // Verify this chat room actually exists
      final storedRoomDoc =
          await _firestore.collection('chatRooms').doc(storedChatRoomId).get();

      if (storedRoomDoc.exists) {
        return storedChatRoomId;
      } else {
        print('Stored chat room ID does not exist in Firestore');
        // Clear the invalid stored ID
        await LocalStorageService.saveChatRoomId(widget.doctor['userId'], '');
      }
    }

    // Generate a truly consistent chat room ID
    List<String> ids = [
      widget.doctor['userId'],
      _chatSendId ?? _auth.currentUser?.uid ?? 'unknown'
    ];
    ids.sort(); // Sort alphabetically for consistency
    final consistentId = '${ids[0]}_${ids[1]}';

    print('Generated consistent ID: $consistentId');

    try {
      // First check directly if this ID exists
      final consistentRoomDoc =
          await _firestore.collection('chatRooms').doc(consistentId).get();

      if (consistentRoomDoc.exists) {
        print('Found existing chat room directly with consistent ID');
        await LocalStorageService.saveChatRoomId(
            widget.doctor['userId'], consistentId);
        return consistentId;
      }

      // If not found directly, check participants in both directions
      final userId = _chatSendId;
      if (userId != null) {
        // Check rooms where current user is a participant
        final userRoomsQuery = await _firestore
            .collection('chatRooms')
            .where('participants', arrayContains: userId)
            .get();

        print(
            'Found ${userRoomsQuery.docs.length} rooms where user is participant');

        for (var doc in userRoomsQuery.docs) {
          final data = doc.data();
          if (data['participants'] != null &&
              (data['participants'] as List)
                  .contains(widget.doctor['userId'])) {
            print('Found existing chat room through user query: ${doc.id}');
            await LocalStorageService.saveChatRoomId(
                widget.doctor['userId'], doc.id);
            return doc.id;
          }
        }

        // Also check rooms where doctor is a participant
        final doctorRoomsQuery = await _firestore
            .collection('chatRooms')
            .where('participants', arrayContains: widget.doctor['userId'])
            .get();

        print(
            'Found ${doctorRoomsQuery.docs.length} rooms where doctor is participant');

        for (var doc in doctorRoomsQuery.docs) {
          final data = doc.data();
          if (data['participants'] != null &&
              (data['participants'] as List).contains(userId)) {
            print('Found existing chat room through doctor query: ${doc.id}');
            await LocalStorageService.saveChatRoomId(
                widget.doctor['userId'], doc.id);
            return doc.id;
          }
        }
      }

      // If no existing room found, create a new one with our consistent ID
      print(
          'No existing chat room found, creating with consistent ID: $consistentId');

      // Store the consistent ID for future reference
      await LocalStorageService.saveChatRoomId(
          widget.doctor['userId'], consistentId);
      return consistentId;
    } catch (e) {
      print('Error in chat room ID creation: $e');

      // Fallback to using our generated consistent ID
      await LocalStorageService.saveChatRoomId(
          widget.doctor['userId'], consistentId);
      return consistentId;
    }
  }

  // Fetch all messages (both sent and received)
  Future<List<Map<String, dynamic>>> fetchAllMessages() async {
    if (_chatRoomId == null) {
      print('Chat room ID is null');
      return [];
    }
    try {
      print('Fetching all messages for chat room: $_chatRoomId');
      final QuerySnapshot messagesSnapshot = await _firestore
          .collection('chatRooms')
          .doc(_chatRoomId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .get();
      print('Fetched ${messagesSnapshot.docs.length} messages');

      // Debug information about senders
      final senderIds = messagesSnapshot.docs
          .map((doc) =>
              (doc.data() as Map<String, dynamic>)['senderId'] as String?)
          .where((id) => id != null)
          .toSet();
      print('Message sender IDs in this chat: $senderIds');
      print('Current user ID: $_chatSendId');

      return messagesSnapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        return {
          ...data,
          'id': doc.id,
        };
      }).toList();
    } catch (e) {
      print('Error fetching all messages: $e');
      return [];
    }
  }

  // Fetch only messages sent by the current user
  Future<List<Map<String, dynamic>>> fetchSentMessages() async {
    if (_chatRoomId == null || _chatSendId == null) {
      print('Chat room ID or user ID is null');
      return [];
    }
    try {
      final QuerySnapshot messagesSnapshot = await _firestore
          .collection('chatRooms')
          .doc(_chatRoomId)
          .collection('messages')
          .where('senderId', isEqualTo: _chatSendId)
          .orderBy('timestamp', descending: true)
          .get();
      print('Fetched ${messagesSnapshot.docs.length} sent messages');

      return messagesSnapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        return {
          ...data,
          'id': doc.id,
        };
      }).toList();
    } catch (e) {
      print('Error fetching sent messages: $e');
      return [];
    }
  }

  // Fetch only messages received from others
  Future<List<Map<String, dynamic>>> fetchReceivedMessages() async {
    if (_chatRoomId == null || _chatSendId == null) {
      print('Chat room ID or user ID is null');
      return [];
    }
    try {
      final QuerySnapshot messagesSnapshot = await _firestore
          .collection('chatRooms')
          .doc(_chatRoomId)
          .collection('messages')
          .where('senderId', isNotEqualTo: _chatSendId)
          .orderBy('senderId') // Need a first ordering when using isNotEqualTo
          .orderBy('timestamp', descending: true)
          .get();
      print('Fetched ${messagesSnapshot.docs.length} received messages');

      return messagesSnapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        return {
          ...data,
          'id': doc.id,
        };
      }).toList();
    } catch (e) {
      print('Error fetching received messages: $e');
      return [];
    }
  }

  // Get the latest message in the chat room
  Future<Map<String, dynamic>?> fetchLatestMessage() async {
    if (_chatRoomId == null) {
      print('Chat room ID is null');
      return null;
    }
    try {
      final QuerySnapshot latestMessageSnapshot = await _firestore
          .collection('chatRooms')
          .doc(_chatRoomId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .limit(1)
          .get();

      if (latestMessageSnapshot.docs.isEmpty) {
        print('No messages found');
        return null;
      }

      final data =
          latestMessageSnapshot.docs.first.data() as Map<String, dynamic>;
      final latestMessage = {
        ...data,
        'id': latestMessageSnapshot.docs.first.id,
      };
      print('Fetched latest message: ${latestMessage['text']}');
      return latestMessage;
    } catch (e) {
      print('Error fetching latest message: $e');
      return null;
    }
  }

  // Refresh messages manually
  Future<void> _refreshMessages() async {
    setState(() {
      isLoading = true;
    });
    try {
      // Recreate the stream to get fresh data
      _messagesStream = _firestore
          .collection('chatRooms')
          .doc(_chatRoomId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .snapshots();

      // Also fetch the latest message to ensure we have it
      final latestMessage = await fetchLatestMessage();
      if (latestMessage != null) {
        print('Latest message refreshed: ${latestMessage['text']}');
      }

      setState(() {
        isLoading = false;
      });
    } catch (e) {
      print('Error refreshing messages: $e');
      setState(() {
        error = 'Failed to refresh messages: $e';
        isLoading = false;
      });
    }
  }

  // Add a function to clear and reload the chat
  Future<void> _reloadChat() async {
    setState(() {
      isLoading = true;
      error = '';
    });

    try {
      // Force re-fetching of chat room ID
      await LocalStorageService.saveChatRoomId(widget.doctor['userId'], '');
      _chatRoomId = await _getOrCreateConsistentChatRoomId();

      print('Reloaded chat with room ID: $_chatRoomId');

      // Re-setup messages stream
      _messagesStream = _firestore
          .collection('chatRooms')
          .doc(_chatRoomId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .snapshots();

      setState(() {
        isLoading = false;
      });
    } catch (e) {
      setState(() {
        error = 'Failed to reload chat: $e';
        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.blue,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Row(
          children: [
            const SizedBox(width: 10),
            Hero(
              tag: 'doctor_${widget.doctor['userId']}',
              child: CircleAvatar(
                backgroundImage: NetworkImage(widget.doctor['image'] ?? ''),
                radius: 20,
                child: widget.doctor['image'] == null
                    ? const Icon(Icons.person, color: Colors.white)
                    : null,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.doctor['name'] ?? 'Unknown Doctor',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  StreamBuilder<DocumentSnapshot>(
                    stream: _firestore
                        .collection('chatRooms')
                        .doc(_chatRoomId)
                        .snapshots(),
                    builder: (context, snapshot) {
                      if (snapshot.hasData && snapshot.data != null) {
                        final data =
                            snapshot.data!.data() as Map<String, dynamic>?;
                        if (data != null && data['status'] == 'active') {
                          return const Text(
                            'Online',
                            style: TextStyle(fontSize: 12, color: Colors.green),
                          );
                        }
                      }
                      return const Text(
                        'Offline',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _reloadChat,
          ),
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () {
              showModalBottomSheet(
                context: context,
                builder: (context) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: const Text('View Profile'),
                      onTap: () {
                        Navigator.pop(context);
                        // Navigate to profile
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.block),
                      title: const Text('Block User'),
                      onTap: () {
                        Navigator.pop(context);
                        // Show block confirmation
                      },
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.blue.withOpacity(0.1),
              Colors.white,
            ],
          ),
        ),
        child: isLoading
            ? const Center(child: CircularProgressIndicator())
            : error.isNotEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.refresh, size: 32, color: Colors.red),
                        const SizedBox(height: 16),
                        Text(
                          error,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.red),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: () {
                            setState(() {
                              isLoading = true;
                              error = '';
                            });
                            _initializeChat();
                          },
                          child: const Text('Retry Connection'),
                        ),
                      ],
                    ),
                  )
                : Column(
                    children: [
                      // Debug information bar
                      Container(
                        color: Colors.grey[200],
                        padding: const EdgeInsets.all(4),
                        child: Text(
                          'Chat ID: $_chatRoomId',
                          style:
                              TextStyle(fontSize: 10, color: Colors.grey[600]),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      Expanded(
                        child: StreamBuilder<QuerySnapshot>(
                          stream: _messagesStream,
                          builder: (context, snapshot) {
                            if (snapshot.hasError) {
                              print('Stream error: ${snapshot.error}');
                              return Center(
                                  child: Text('Error: ${snapshot.error}'));
                            }
                            if (snapshot.connectionState ==
                                ConnectionState.waiting) {
                              return const Center(
                                  child: CircularProgressIndicator());
                            }
                            final messages = snapshot.data?.docs ?? [];
                            if (messages.isEmpty) {
                              return Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(Icons.chat_bubble_outline,
                                        size: 48, color: Colors.grey),
                                    const SizedBox(height: 16),
                                    Text(
                                      'No messages yet',
                                      style: TextStyle(color: Colors.grey[600]),
                                    ),
                                  ],
                                ),
                              );
                            }

                            return ListView.builder(
                              reverse: true,
                              padding: const EdgeInsets.all(16),
                              itemCount: messages.length,
                              itemBuilder: (context, index) {
                                final message = messages[index].data()
                                    as Map<String, dynamic>;
                                final messageId = messages[index].id;
                                final isMe = message['senderId'] == _chatSendId;
                                final senderName = message['senderName'] ??
                                    (isMe ? 'You' : 'Doctor');
                                final messageStatus =
                                    message['status'] ?? 'sent';

                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Row(
                                    mainAxisAlignment: isMe
                                        ? MainAxisAlignment.end
                                        : MainAxisAlignment.start,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      if (!isMe) ...[
                                        CircleAvatar(
                                          backgroundImage: NetworkImage(
                                              widget.doctor['image'] ?? ''),
                                          radius: 16,
                                          child: widget.doctor['image'] == null
                                              ? const Icon(Icons.person,
                                                  size: 16, color: Colors.white)
                                              : null,
                                        ),
                                        const SizedBox(width: 8),
                                      ],
                                      Flexible(
                                        child: GestureDetector(
                                          onLongPress: isMe
                                              ? () {
                                                  showModalBottomSheet(
                                                    context: context,
                                                    builder: (context) =>
                                                        Column(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        ListTile(
                                                          leading: const Icon(
                                                              Icons.edit),
                                                          title: const Text(
                                                              'Edit Message'),
                                                          onTap: () {
                                                            Navigator.pop(
                                                                context);
                                                            _startEditing(
                                                                messageId,
                                                                message[
                                                                    'text']);
                                                          },
                                                        ),
                                                        ListTile(
                                                          leading: const Icon(
                                                              Icons.delete,
                                                              color:
                                                                  Colors.red),
                                                          title: const Text(
                                                              'Delete Message'),
                                                          onTap: () {
                                                            Navigator.pop(
                                                                context);
                                                            showDialog(
                                                              context: context,
                                                              builder:
                                                                  (context) =>
                                                                      AlertDialog(
                                                                title: const Text(
                                                                    'Delete Message'),
                                                                content: const Text(
                                                                    'Are you sure you want to delete this message?'),
                                                                actions: [
                                                                  TextButton(
                                                                    onPressed: () =>
                                                                        Navigator.pop(
                                                                            context),
                                                                    child: const Text(
                                                                        'Cancel'),
                                                                  ),
                                                                  TextButton(
                                                                    onPressed:
                                                                        () {
                                                                      Navigator.pop(
                                                                          context);
                                                                      _deleteMessage(
                                                                          messageId);
                                                                    },
                                                                    child: const Text(
                                                                        'Delete',
                                                                        style: TextStyle(
                                                                            color:
                                                                                Colors.red)),
                                                                  ),
                                                                ],
                                                              ),
                                                            );
                                                          },
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                }
                                              : null,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 16, vertical: 10),
                                            decoration: BoxDecoration(
                                              color: isMe
                                                  ? Colors.blue
                                                  : Colors.white,
                                              borderRadius: BorderRadius.only(
                                                topLeft: Radius.circular(
                                                    isMe ? 20 : 5),
                                                topRight: Radius.circular(
                                                    isMe ? 5 : 20),
                                                bottomLeft: Radius.circular(20),
                                                bottomRight:
                                                    Radius.circular(20),
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.black
                                                      .withOpacity(0.1),
                                                  blurRadius: 4,
                                                  offset: const Offset(0, 2),
                                                ),
                                              ],
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                if (!isMe) ...[
                                                  Text(
                                                    senderName,
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      color: Colors.black,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 4),
                                                ],
                                                Text(
                                                  message['text'],
                                                  style: TextStyle(
                                                    color: isMe
                                                        ? Colors.white
                                                        : Colors.black,
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Text(
                                                      DateFormat('hh:mm a')
                                                          .format((message[
                                                                      'timestamp']
                                                                  as Timestamp)
                                                              .toDate()),
                                                      style: TextStyle(
                                                        color: isMe
                                                            ? Colors.white70
                                                            : Colors.grey[600],
                                                        fontSize: 10,
                                                      ),
                                                    ),
                                                    if (isMe) ...[
                                                      const SizedBox(width: 4),
                                                      Icon(
                                                        messageStatus == 'sent'
                                                            ? Icons.check
                                                            : Icons
                                                                .check_circle,
                                                        size: 12,
                                                        color: Colors.white70,
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                      if (isMe) ...[
                                        const SizedBox(width: 8),
                                        CircleAvatar(
                                          radius: 16,
                                          backgroundColor: Colors.blue,
                                          child: const Icon(
                                            Icons.person,
                                            size: 16,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.all(8),
                        child: Row(
                          children: [
                            if (_isEditing) ...[
                              IconButton(
                                icon:
                                    const Icon(Icons.close, color: Colors.red),
                                onPressed: _cancelEditing,
                              ),
                            ] else ...[
                              IconButton(
                                icon: const Icon(Icons.attach_file,
                                    color: Colors.blue),
                                onPressed: () {
                                  // Handle attachment
                                },
                              ),
                            ],
                            Expanded(
                              child: TextField(
                                controller: _messageController,
                                decoration: InputDecoration(
                                  hintText: _isEditing
                                      ? 'Edit message...'
                                      : 'Type a message...',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(25),
                                    borderSide: BorderSide.none,
                                  ),
                                  filled: true,
                                  fillColor: Colors.grey[100],
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                    vertical: 10,
                                  ),
                                ),
                                maxLines: null,
                                onSubmitted: (_) => _isEditing
                                    ? _updateMessage()
                                    : sendMessage(),
                              ),
                            ),
                            IconButton(
                              icon: Icon(
                                _isEditing ? Icons.check : Icons.send,
                                color: Colors.blue,
                              ),
                              onPressed:
                                  _isEditing ? _updateMessage : sendMessage,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }
}
