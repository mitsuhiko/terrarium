"""Local notifications: delivered later, even when the program (or the app) isn't running.

    import notification
    notification.schedule("Tea is ready!", delay=180, sound_name="default")

A notification can carry a URL that opens when it is tapped, e.g. a
terrarium://run?path=… link to run a program. The first use asks for permission.
"""

from _device import call, file_ref

__all__ = ["schedule", "cancel", "cancel_all", "get_scheduled", "remove_delivered", "remove_all_delivered"]


def schedule(message=None, delay=0, sound_name=None, action_url=None, title=None, subtitle=None,
             attachments=None, trigger=None, actions=None, identifier=None):
    """Schedule a notification; returns its identifier.

    - delay: seconds from now (ignored when trigger is given)
    - sound_name: None (silent) or 'default'
    - action_url: opened when the notification is tapped
    - attachments: files (e.g. images) shown with it
    - trigger: a dict of calendar components ('year', 'month', 'day', 'weekday',
      'hour', 'minute', 'second', 'repeats') or a location ('latitude',
      'longitude', 'radius', 'entry', 'exit', 'repeats')
    - actions: buttons, dicts with 'title', 'url', 'destructive', 'text_input'
      ('{text_input}' in the url is replaced by what was typed)
    - identifier: replaces a scheduled notification with the same identifier
    """
    return call(
        "notification.schedule", message=message, delay=float(delay or 0), sound_name=sound_name,
        action_url=action_url, title=title, subtitle=subtitle,
        attachments=[file_ref(p) for p in (attachments or [])], trigger=trigger,
        actions=[{**a, "url": a.get("url", a.get("action_url"))} for a in (actions or [])], identifier=identifier,
    )


def cancel(identifier):
    """Cancel a scheduled notification."""
    call("notification.cancel", identifier=str(identifier))


def cancel_all():
    """Cancel all scheduled notifications."""
    call("notification.cancelAll")


def get_scheduled():
    """The identifiers of the scheduled notifications."""
    return call("notification.scheduled") or []


def remove_delivered(identifier):
    """Remove a delivered notification from Notification Center."""
    call("notification.removeDelivered", identifier=str(identifier))


def remove_all_delivered():
    """Remove all of this app's delivered notifications."""
    call("notification.removeAllDelivered")
