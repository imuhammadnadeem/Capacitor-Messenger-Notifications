import type { PermissionState } from '@capacitor/core';

export interface PermissionStatus {
  notifications: PermissionState;
}

export interface MessengerNotificationsPlugin {
  /**
   * Shows a native notification, grouped by room.
   */
  showNotification(options: {
    title: string;
    body: string;
    roomId: number;
    messageId?: string;
    timestamp?: number;
    roomName?: string;
    senderId?: number;
    avatarSvg?: string;
  }): Promise<void>;

  /**
   * Clears notifications for a specific room.
   */
  clearRoomNotification(options: { roomId: number }): Promise<void>;

  /**
   * Returns the roomId that triggered the app launch, if any.
   */
  getPendingRoomId(): Promise<{ roomId: number | null }>;

  /**
   * Starts a persistent background service (Android only) that maintains a socket connection.
   */
  startPersistentSocket(options: { url: string; token: string }): Promise<void>;

  /**
   * Stops the persistent background service.
   */
  stopPersistentSocket(): Promise<void>;

  /**
   * Check notification permissions.
   */
  checkPermissions(): Promise<PermissionStatus>;

  /**
   * Request notification permissions.
   */
  requestPermissions(): Promise<PermissionStatus>;

  /**
   * Registers push credentials with your backend using `safe_storage` (JWT + base URL required).
   * Android: FCM only. iOS: FCM (`/api/users/fcm-token`) and/or OneSignal (`/api/push/register`) when both are stored.
   */
  registerFcmToken(): Promise<void>;
}
