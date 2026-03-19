import { registerPlugin } from '@capacitor/core';

import type { MessengerNotificationsPlugin } from './definitions';

const MessengerNotifications = registerPlugin<MessengerNotificationsPlugin>('MessengerNotifications', {
  web: () => import('./web').then((m) => new m.MessengerNotificationsWeb()),
});

export * from './definitions';
export { MessengerNotifications };
