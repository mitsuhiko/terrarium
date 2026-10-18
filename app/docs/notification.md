# notification — Local notifications

Notifications that arrive later, at a time or a place, even when the program
or the app isn't running. A notification can carry a link that opens when
it is tapped: a `terrarium://run?path=…` link runs a program. The first use
asks for permission.

```python
import notification

notification.schedule("Tea is ready!", delay=180, title="Timer", sound_name="default")
```

## Functions

### notification.schedule(message=None, delay=0, sound_name=None, action_url=None, title=None, subtitle=None, attachments=None, trigger=None, actions=None, identifier=None)

Schedule a notification; returns its identifier.

- `delay`: seconds from now (0 shows it right away).
- `sound_name`: None for a silent notification, `'default'` for the sound.
- `action_url`: a link opened when the notification is tapped.
- `title`, `subtitle`: shown above the message.
- `attachments`: files (e.g. an image) shown with it.
- `trigger`: instead of `delay`, a dict of calendar parts (`'year'`,
  `'month'`, `'day'`, `'weekday'`, `'hour'`, `'minute'`, `'second'`,
  `'repeats'`) or a place (`'latitude'`, `'longitude'`, `'radius'` in
  meters, `'entry'`, `'exit'`, `'repeats'`).
- `actions`: buttons, as dicts with `'title'`, `'url'`, `'destructive'` and
  `'text_input'` (`'{text_input}'` in the url becomes what was typed).
- `identifier`: replaces a scheduled notification with the same
  identifier.

```python
# Every day at 8:00
notification.schedule("Time to practice!", trigger={"hour": 8, "minute": 0, "repeats": True})
```

### notification.cancel(identifier)

Cancel a scheduled notification.

### notification.cancel_all()

Cancel all scheduled notifications.

### notification.get_scheduled()

The identifiers of the scheduled notifications.

### notification.remove_delivered(identifier)

Remove a delivered notification from Notification Center.

### notification.remove_all_delivered()

Remove all of this app's delivered notifications.
