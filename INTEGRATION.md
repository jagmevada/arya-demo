# Arya voice demo: integration note for the office launch simulator

Source: `jagmevada/arya-demo`, single file `index.html` (page version 37). Live page: https://jagmevada.github.io/arya-demo/

This note describes what the web demo does, how to connect it to the office space launch simulator, and gives the reminder and situational-awareness features in a form that can be ported directly. All mission values, limits and procedures in the demo are placeholders written for the demo. None of them are flight data or ISRO procedures.

## 1. Pipeline

| Stage | Service | Model / endpoint | Measured on phone |
|---|---|---|---|
| Speech to text | Cartesia Ink | `ink-2`, `wss://api.cartesia.ai/stt/websocket`, PCM s16le 16 kHz | 0.1 to 0.3 s |
| Brain | Anthropic Messages API | `claude-haiku-5-5` (default) or `claude-sonnet-5-5`, tool use | Sonnet 2 to 5 s; Haiku not measured in the field logs |
| Text to speech | Cartesia Sonic | `sonic-3.6`, `POST https://api.cartesia.ai/tts/bytes`, raw PCM s16le 24 kHz, streamed | 0.2 to 0.5 s to first audio |

Cartesia API version header used: `2026-08-14`. Default voice: Aarti, ID `9cebb910-d4b7-4a4a-85a4-12c79137724c` (ID taken from a third-party voice list, then confirmed working in the demo). TTS language is set to `hi` when the reply contains Devanagari, otherwise `en`.

One turn: mic audio is sent to Ink over a WebSocket opened per utterance, the transcript goes to Claude with the live console snapshot and the tool list, Claude's text goes to Sonic, and the audio is played as it arrives.

## 2. What must change for office use

| Item | In the demo | For the office simulator |
|---|---|---|
| Data source | In-page simulator (`sim` object, section "mission simulator") | Replace `snapshot()`, `nextEvents()`, `nextContacts()` and `runTool()` with calls to the launch simulator |
| API keys | Typed into the page, kept in browser `localStorage` | Keep keys on a server. For Cartesia, the server mints short-lived access tokens (`POST /access-token`). For Anthropic, proxy the Messages call |
| Timeline, limits, SOPs | Placeholders (`PROFILE`, `MILESTONES`, `ANOM`, `SOPS`, `ESCALATE`) | Real mission timeline, real caution and warning limits, approved procedures |
| Mic capture | `ScriptProcessorNode`, simple box-filter resample to 16 kHz | AudioWorklet and a proper resampler if audio quality matters |
| Hosting | GitHub Pages, public repo | Internal host |

## 3. Tools Claude can call

These are the tool definitions in the demo. The names and inputs can stay the same when the back end changes.

| Tool | Purpose | Input |
|---|---|---|
| `console_status` | Live readings by section | `section`: mission, cabin, alerts, lights, camera, calls, computer, all |
| `mission_timeline` | Next events, next contacts, next ground station | none |
| `get_sop` | Procedure steps, fix command and live safety assessment for an alert | `alert_id` (optional, defaults to latest active) |
| `console_command` | Run the command that fixes a fault | `command` |
| `set_cabin_lights` | Spots, zones, dimming | `spots_on/off`, `zones_on/off`, `all_on`, `all_off`, `dim_percent` |
| `set_camera` | Camera preview view | `view` |
| `video_call` | Call a contact or hang up; needs ground contact | `action`, `contact` |
| `acknowledge_alert` | Acknowledge one alert or all | `id` |
| `set_reminder` | Reminder or countdown that Arya speaks by herself | see section 4 |
| `cancel_reminders` | Cancel pending reminders | none |
| `simulator` | Start, restart, hold, resume, jump to a major event | `action`, `quick`, `event` |
| `inject_fault` | Trigger a simulated fault for SOP practice | `alert_id` |

Design rule that halved response time: the current console snapshot, timeline and safety figures are placed in the system prompt of every request. Claude then answers status questions in one call and uses tools only to change something, to fetch procedure steps, or to control the simulator.

## 4. Reminder feature (to port)

The crew can ask in normal speech, in English or Hindi:

- "Remind me 10 seconds before orbit insertion."
- "Count down every 30 seconds until orbit insertion."
- "Remind me in 30 seconds to switch off zone 5."
- "Tell me to restart the cabin fan when insertion is done."
- "Cancel the reminders."

Arya then speaks the reminder by herself at the right mission time. This worked in the field test on 10 November 2026, including the Hindi requests.

### 4.1 Tool definition

```js
{ name: "set_reminder",
  description: "Make yourself speak a reminder later, without being asked again. Either give event + seconds_before (\"remind me 10 seconds before orbit insertion\"), or in_seconds from now (\"remind me in 2 minutes to check the valve\"). With event + repeat_every_seconds you count down aloud at that interval until the event. Seconds are mission-clock seconds. message is the exact words you will say then, in the crew's language; leave it out for a countdown.",
  input_schema: { type: "object", properties: {
    event: { type: "string", enum: [/* names of the mission events */] },
    seconds_before: { type: "number" },
    in_seconds: { type: "number" },
    repeat_every_seconds: { type: "number" },
    message: { type: "string" } } } },
{ name: "cancel_reminders",
  description: "Cancel all pending reminders and countdowns.",
  input_schema: { type: "object", properties: {} } }
```

### 4.2 Tool handler

`sim.t` is the mission clock in seconds (negative before liftoff). `MILESTONES` is a list of `[missionSeconds, eventName, ...]`. `sim.reminders` is a list of `{ at, text }`.

```js
case "cancel_reminders": { const n = sim.reminders.length; sim.reminders = []; return { done: true, cancelled: n }; }
case "set_reminder": {
  const ev = a.event && MILESTONES.find(m => m[1] === a.event);
  const left = x => { x = Math.round(x); const m = Math.floor(x / 60), sec = x % 60;
    return x < 120 ? x + " seconds" : m + " minutes" + (sec ? " " + sec + " seconds" : ""); };
  let list = [];
  if (ev) {
    if (ev[0] <= sim.t) return { done: false, reason: a.event + " has already happened" };
    const mk = x => ({ at: ev[0] - x, text: a.message && !a.repeat_every_seconds ? a.message : left(x) + " to " + a.event + "." });
    if (a.repeat_every_seconds > 0) {            // countdown: at most 40 callouts, no closer than 5 s apart
      const step = Math.max(5, a.repeat_every_seconds);
      for (let x = Math.floor((ev[0] - sim.t - 1) / step) * step; x >= step && list.length < 40; x -= step) list.push(mk(x));
    } else list.push(mk(Math.max(0, a.seconds_before ?? 10)));
    list = list.filter(r => r.at > sim.t);
    if (!list.length) return { done: false, reason: "too late: " + a.event + " is only " + fmtDur(ev[0] - sim.t) + " away" };
  } else if (a.in_seconds > 0) list.push({ at: sim.t + a.in_seconds, text: a.message || "Reminder." });
  else return { done: false, reason: "give an event, or in_seconds" };
  sim.reminders.push(...list);
  return { done: true, reminders_set: list.length, first_in: fmtDur(list[0].at - sim.t),
           note: "You will speak them by yourself; confirm in a few words." };
}
```

### 4.3 Firing, in the simulator tick

```js
if (sim.reminders.some(r => sim.t >= r.at)) {
  sim.reminders.filter(r => sim.t >= r.at).forEach(r => say(r.text, true));
  sim.reminders = sim.reminders.filter(r => sim.t < r.at);
}
```

`say(text, keep, urgent, valid)` puts a line in the speech queue. The speech loop takes one line at a time when Arya is idle and sends it to Sonic.

### 4.4 Prompt lines that make Claude use it

```
You do speak on your own: this console announces every new caution, warning and mission event aloud in your voice the moment it happens, without the crew asking. Never say that you can only speak when spoken to.
You can also remind and count down: when the crew asks "remind me when…", "tell me 10 seconds before…", "count down every 10 seconds", call set_reminder straight away. Never say you cannot set a reminder or count down. Reminders pending now: <count>.
```

Without these lines Claude refused ("I cannot set reminders, I only answer when asked").

### 4.5 Timed actions (added in page version 37)

The crew can also ask Arya to do something later, not only to remind:

- "After 30 seconds switch off all lights."
- "At orbit insertion switch to the window camera."

`set_reminder` takes an optional `action`: the tool to run and its input. At the set time the page runs that tool and Arya then says `message`, or says why the action did not work.

```js
// extra property in the set_reminder input schema
action: { type: "object", properties: { tool: { type: "string", enum: TIMED_TOOLS }, input: { type: "object" } }, required: ["tool", "input"] }

const TIMED_TOOLS = ["set_cabin_lights", "set_camera", "console_command", "acknowledge_alert"];

// firing
sim.reminders.filter(r => sim.t >= r.at).forEach(r => {
  if (!r.run) return say(r.text, true);
  const res = runTool(r.run.tool, r.run.input || {});
  say(res.done === false ? "The timed action did not work: " + (res.reason || "no change") + "." : r.text, true);
});
```

Calls and mission control (start, hold, jump) are deliberately not allowed on a timer. Prompt line: "You can also act on a timer … call set_reminder with action; never offer a reminder instead of doing it." Tested in a simulated run only, not yet by voice.

### 4.6 Behaviour to keep in mind

- Seconds are mission-clock seconds. If the simulator runs faster than real time, a "10 second" reminder passes faster in real time.
- A reminder set relative to an event that already passed is refused with a reason, and Arya says so.
- An event-triggered reminder with seconds_before 0 gives "tell me when X happens".
- The `message` text is written by Claude in the crew's language, so Hindi requests give Hindi reminders. Automatic countdown text is English.

## 5. Situational-awareness features (to port)

Purpose: keep a busy crew aware without making them look at the screen or ask.

| Feature | Behaviour | Demo setting |
|---|---|---|
| Event callouts | Arya announces each mission event, some with live altitude and velocity | `MILESTONES` |
| Alert callout | "Caution. …" or "Warning. …" the moment a fault starts | `ANOM` |
| Warning priority | A warning goes to the front of the speech queue | `urgent` flag in `say()` |
| Reminder of unacknowledged alert | Repeats with the live value and its limit until acknowledged | every 75 s real time (`REMIND_MS`) |
| Worsening value | Spoken once when a value crosses a worse threshold, even after acknowledgement | `ESCALATE`: CO2 0.8 %, pressure 96 and 88 kPa, temperature 24.3 °C |
| Signal events | "Acquisition of signal, …" and "Loss of signal." | on contact change |
| Stale-line check | A queued line is tested just before speaking and dropped if no longer true (for example a reminder for an alert that was acknowledged meanwhile) | `valid` function in `say()` |
| Clock and speech in step | The simulator clock waits while a mission event is still queued to be spoken | `waiting` in `simTick()` |
| Sitrep | "Status", "what did I miss": phase and clock, active alert with value and limit, next event | prompt section "Situational awareness" |

Core of the reminder and worsening logic:

```js
ESCALATE.forEach(([id, test, text], i) => {
  if (active(id) && !sim.fired.has("esc" + i) && test()) { sim.fired.add("esc" + i); say(text(), true, true, () => active(id)); }
});
for (const a of sim.alerts) if (active(a.id) && !a.acknowledged && now - a.saidAt > REMIND_MS && !sim.announce.length) {
  a.saidAt = now;
  say("Reminder. " + a.text + ", not acknowledged. " + NOW[a.id](), true, false, () => active(a.id) && !a.acknowledged);
}
```

## 6. Prompt rules learned in testing

Each rule below fixed a problem seen in the field test.

| Problem seen | Rule added |
|---|---|
| Arya "corrected" her earlier answers because telemetry had moved | Each crew message is stamped with the mission clock. Prompt: older numbers are old readings, not errors; never mention an earlier answer |
| Long answers, slow replies | At most two short sentences, about 25 words; three for "how does it work" |
| Refused "how does the scrubber work?" | Scope widened to technical questions on the vehicle, its systems and the mission, answered from general engineering knowledge, with no invented design figures |
| Said "I cannot start the mission" | `simulator` tool plus a prompt line that this overrides the "never touch the mission" rule |
| Said "I cannot speak on my own" | Prompt line stating that the console announces events in her voice |
| Spelled ISTRAC letter by letter | Pronunciation list applied to the text before Sonic (ISTRAC → Estrack, ISRO → Isro, SHAR → Shaar, SAC → Sack). Editable in Settings |
| Read "2.3 g" as grams | Number followed by `g` is spoken as "gee" |
| Refused Hindi | Reply in the language of the crew's latest request; Hindi in Devanagari with technical words kept in English |

Note: the project file `ARYA.md` still says English only and does not include these rules. The demo page carries its own copy of the prompt.

## 7. Reliability lessons

- Every `tool_use` block must get a `tool_result`, whatever the stop reason. A missing result makes the API reject the whole conversation (HTTP 400). On a 400 the demo clears the conversation so the next question works.
- Sonic requests are retried twice on a network error or a busy response.
- The audio context must be created and resumed inside the tap itself. Resuming it after the mic permission prompt left it suspended on Android Chrome, and the first turns got no sound.
- A mic health check before each turn gave false alarms on a working mic and was removed. The mic is restarted only after a turn that received no audio at all.
- The final count (five to one, liftoff) is fetched as six clips in advance and placed on the audio clock one second apart, so network delay cannot shift it.
- Ink key terms (Arya, ISTRAC, Sriharikota and others) are sent as repeated `keyterm` query parameters. This format was not verified against the Cartesia documentation; the page switches it off by itself if the connection is refused.

## 8. Demo controls

- Talk button: tap to unmute and tap again to send, or hold and release. A tap while Arya speaks stops her.
- Start options: with brief from T minus 50 s, or no brief from T minus 10 s.
- Speed: 1×, 4×, 12×. The countdown always runs in real time.
- Jump to: liftoff, S200 separation, orbit insertion, deorbit burn, entry interface, drogue parachutes, splashdown.
- Fault buttons: fan 2 speed low, carbon dioxide high, pressure dropping, link 1 lost. A fixed fault can be triggered again.
- "Copy log for diagnosis": copies the conversation, timings, errors, version and mic state.
