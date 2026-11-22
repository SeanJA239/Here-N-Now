# StandBy and widget assessment (P1)

The PRD lists StandBy and widgets as "P1, decide after capability checks" and says they must not be treated as equivalent to the full patient screen. This note records what was checked and the resulting decision. Nothing here is built yet.

## What a widget could and could not do

| Need from the PRD | Widget / StandBy capability | Fit |
| --- | --- | --- |
| Show the time-of-day word and one sentence | A timeline of precomputed entries can show text and one image | Possible |
| Remove an event exactly at its "显示至" time | Entries can be scheduled at known times, but the system decides refresh timing and budgets reloads | Approximate only; must be verified on devices |
| Apply a new version from the caregiver | Widgets do not sync on their own; the app must write shared data and ask for a reload, which needs the app to run | Weak while the app is not running |
| "听一听" plays a family recording | Widgets cannot play audio; an App Intent could open the app | Not equivalent |
| Revocation and the 7-day offline lease | The widget only shows what the app last wrote; it cannot check the server | Must hide content when the app clears shared data |
| Large text, 4.5:1 contrast | StandBy renders widgets large and may tint them in night mode, which changes our palette | Needs device testing |

StandBy is an iPhone feature shown while the phone is charging on its side. The patient display in this project is an iPad, so StandBy does not cover the main use. Widget behaviour on the patient iPad's Home Screen and Lock Screen would need its own checks on real devices.

## Blocked on Apple Developer access

Sharing data between the app and a widget extension needs an App Group entitlement, which requires signing with an Apple Developer team. This project does not have one yet. A widget would also be a second display path that must follow every P0 rule (expiry, revocation, lease), which is real risk for little benefit while the main screen already works.

## Decision

Do not build a widget in this round. Revisit once there is a developer team and a pilot family with an iPhone on a charger in the room, then test on real devices:

1. Whether reloads arrive in time for event start and "显示至" boundaries across a full day.
2. How StandBy night mode tints the palette, and whether text stays readable.
3. That clearing shared data on revocation or lease expiry removes the content from the widget.
