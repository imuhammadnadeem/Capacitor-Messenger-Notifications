import { WebPlugin } from '@capacitor/core';

import type { MessengerNotificationsPlugin, PermissionStatus } from './definitions';

export class MessengerNotificationsWeb extends WebPlugin implements MessengerNotificationsPlugin {
  async showNotification(options: {
    title: string;
    body: string;
    roomId: number;
    messageId?: string;
    timestamp?: number;
    roomName?: string;
  }): Promise<void> {
    console.log('[MessengerNotificationsWeb] showNotification:', options);
    if ('Notification' in window) {
      if (Notification.permission === 'granted') {
        new Notification(options.title, {
          body: options.body,
          data: { roomId: options.roomId, messageId: options.messageId },
        });
      }
    }
  }

  async clearRoomNotification(options: { roomId: number }): Promise<void> {
    console.log('[MessengerNotificationsWeb] clearRoomNotification:', options);
  }

  async getPendingRoomId(): Promise<{ roomId: number | null }> {
    return { roomId: null };
  }

  async startPersistentSocket(options: { url: string; token: string }): Promise<void> {
    console.log('[MessengerNotificationsWeb] startPersistentSocket (not supported on web):', options);
  }

  async stopPersistentSocket(): Promise<void> {
    console.log('[MessengerNotificationsWeb] stopPersistentSocket (not supported on web)');
  }

  async checkPermissions(): Promise<PermissionStatus> {
    if ('Notification' in window) {
      const state =
        Notification.permission === 'granted' ? 'granted' : Notification.permission === 'denied' ? 'denied' : 'prompt';
      return { notifications: state };
    }
    return { notifications: 'denied' };
  }

  async requestPermissions(): Promise<PermissionStatus> {
    if ('Notification' in window) {
      const permission = await Notification.requestPermission();
      const state = permission === 'granted' ? 'granted' : permission === 'denied' ? 'denied' : 'prompt';
      return { notifications: state };
    }
    return { notifications: 'denied' };
  }
}
