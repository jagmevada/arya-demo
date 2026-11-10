# Arya voice demo: integration note for the office launch simulator

Source: `jagmevada/arya-demo`, single file `index.html` (page version 78, 10 November 2026). Live page: https://jagmevada.github.io/arya-demo/

This note describes what the web demo does, how to connect it to the office space launch simulator, and gives the reminder and situational-awareness features in a form that can be ported directly. All mission values, limits and procedures in the demo are placeholders written for the demo. None of them are flight data or ISRO procedures.

Sections 9 to 12 cover the open-model brain, the model comparison, the air-gapped plan and the office test plan. They were added after the first issue of this note (page version 37).

## 1. Pipeline

| Stage | Service | Model / endpoint | Measured on phone |
|---|---|---|---|
| Speech to text | Cartesia Ink | `ink-2`, `wss://api.cartesia.ai/stt/websocket`, PCM s16le 16 kHz | 0.1 to 0.3 s |
| Brain, option A | Anthropic Messages API | `claude-haiku-5-5` (default) or `claude-sonnet-5-5`, tool use | Sonnet 2 to 5 s; Haiku not measured in the field logs |
| Brain, option B | Any OpenAI-compatible `/chat/completions` server (OpenRouter, Cerebras, local Ollama or vLLM) | Open-weight model with tool calling, see sections 9 and 10 | 1.0 to 2.8 s for a plain question, 2 to 4 s for an action (hosted) |
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
| `simulator` | Start, restart, hold, resume, jump to a major event, set speed | `action`, `quick`, `event`, `speed` (1, 4 or 12) |
| `set_reply_language` | Switch the spoken language for the session | `language`: english or hindi |
| `inject_fault` | Trigger a simulated fault for SOP practice | `alert_id` |

Design rule that halved response time: the current console snapshot, timeline and safety figures are placed in the system prompt of every request. Claude then answers status questions in one call and uses tools only to change something or to control the simulator.

The snapshot now also carries, for every active alert, the full ordered procedure (`procedure_now`) and the live safety line (`safety_now`), plus the complete remaining timeline and the splashdown zone. This was added after open models answered from guesswork when the data was only reachable through a tool: one invented a landing site and time, another skipped the first step of a procedure because it derived the step from a command name.

Second speed rule (version 71): for `set_cabin_lights`, `set_camera`, `set_reminder` and `cancel_reminders`, the model is asked to write the spoken confirmation in the same message as the tool call. If the tool reports success, that sentence is spoken and the second model call is skipped. If the tool fails or the model wrote no sentence, the normal second call runs.

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

Calls and mission control (start, hold, jump) are deliberately not allowed on a timer. Prompt line: "You can also act on a timer … call set_reminder with action; never offer a reminder instead of doing it." Confirmed by voice on 10 November 2026 (see 4.7).

### 4.6 Regular callouts of a live reading (version 72)

"Tell me the cabin pressure every 30 seconds" or a procedure step such as "watch the value for 5 minutes". `set_reminder` takes `report` (one of `cabin_pressure`, `carbon_dioxide`, `temperature`, `oxygen`, `altitude`, `velocity`, `g_load`), `repeat_every_seconds` and `for_seconds` (default 300), with no event. The value is read when each callout is due, not when it was requested.

```js
const READINGS = { cabin_pressure: ["Cabin pressure", () => snapshot("cabin").pressure], /* ... */ };

// in set_reminder, before the event branch
if (a.report || (!ev && a.repeat_every_seconds > 0)) {
  const step = Math.max(5, a.repeat_every_seconds || 30), n = Math.min(40, Math.max(1, Math.floor((a.for_seconds || 300) / step)));
  for (let i = 1; i <= n; i++) list.push({ at: sim.t + step * i, report: a.report, text: a.message || "Reminder." });
}

// firing
if (r.report) return say(READINGS[r.report][0] + " " + READINGS[r.report][1]() + ".", true);
```

Reason for the feature: a crew member asked for a pressure update every 30 seconds and the model, having only event countdowns available, counted down to an unrelated event.

### 4.7 Safeguards added for timed actions (versions 70 to 72)

- The action input is validated when the timer is set, not when it fires. An input with no recognised light field used to change nothing and was still announced as done.
- Every timer writes a line to the log: `Timer set for T+01:04:43: set_cabin_lights {"all_off":"true"}` or `speech only`. A copied log then shows whether a real action or only a sentence was scheduled.
- The list of pending timers is placed in the prompt, so the model can answer "are you sure?" truthfully.
- Timed actions were confirmed by voice with Ministral 3 14B, Gemma 4 26B and Qwen 3.8 27B.

### 4.8 Behaviour to keep in mind

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

Rules added during the open-model tests (versions 49 to 78):

| Problem seen | Rule added |
|---|---|
| Invented landing site, times, reasons, equipment ("thermal suit or blanket"), a "heating system" | Every time, place, value, reason, rule, piece of equipment and remedy must come from the snapshot, a tool result or a procedure. If it is not there, say it is not on the console |
| Skipped step 1 of a procedure | Steps are in the snapshot; start at step 1, never skip or reorder, move on only when the crew confirms a step |
| Ran the next procedure command when the crew only confirmed the previous step | Read the step, offer the action, run it only after the crew says yes |
| Same sentence repeated when the crew asked again; "I can only help with the console and the mission" to a crew member who felt unwell | Never repeat the last answer; acknowledge discomfort briefly, give the reading once, offer real help (inform the Flight Director, remind at next contact, keep reporting the reading) |
| Refused a joke, read out cabin values to "I am bored" | With no warning active: one short clean joke or a real remark about the flight |
| Informal tone, emojis, "sir" in every reply | Professional flight-controller register, no emojis, आप never तुम, "sir" allowed in one reply out of five (enforced by a counter in the page, not by the model) |
| Hindi words for standard terms, English terms written in Devanagari | Standard terms stay in English letters in every language; CO2 is spoken "C O two" |
| "44.4 S" read as a letter | The snapshot gives "South", "West" as words |
| Silence ("...") in push-to-talk | In push-to-talk every utterance is for Arya; an unclear one gets a short question. The page retries an empty answer once and then says "Say again, please." |
| Answered about the wrong alert, or repeated her last answer to "what happened?" | "It" means the newest active alert; "what happened?" just after an announcement means that announcement |

A lesson about rule wording: a strict rule fixes one model and can make another worse. The rule "give the cabin reading and say the console has no control" stopped one model inventing a blanket, and made a more obedient model repeat that sentence three times. Rules are now written as a behaviour with alternatives, not as a fixed sentence.

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
- Speed can also be set by voice ("run at 4 times speed").
- Trigger a fault (menu, or by voice: "simulate smoke"): the nine faults in the table below. A fixed fault can be triggered again. On trigger the reading jumps past its alarm point at once, so the card agrees with the alert. The page shows "Triggered: ..." or the reason for refusal.
- Reply language: same as the crew, always English, or Hindi by translation (section 9.3).
- "Copy log for diagnosis": copies the conversation, timings, errors, version and mic state.

Faults and their console fix (all demo placeholders):

| Fault | Level | Fires by itself | Console fix |
|---|---|---|---|
| Cabin fan 2 speed low | Caution | T+07:00 | `restart_cabin_fan_2` (refused during ascent) |
| Cabin carbon dioxide high | Caution | T+28:20 | `switch_co2_scrubber_b` |
| Cabin pressure dropping | Warning | T+43:20 | `close_cabin_vent_valve` |
| Communication link 1 lost | Caution | T+55:00 | `select_comm_link_2` |
| Cabin oxygen low | Caution | no | `open_oxygen_makeup_valve` |
| Cabin temperature high | Caution | no | `select_coolant_loop_2` |
| Smoke detected in cabin | Warning | no | `isolate_avionics_bay_2_power` |
| Main bus B voltage low | Caution | no | `tie_bus_b_to_bus_a` |
| Flight computer 1 fault | Caution | no | `switch_to_flight_computer_2` |

## 9. Open-model brain (for the air-gapped build)

Claude cannot run air-gapped, so the page can use any server that speaks the OpenAI chat-completions format. Settings: provider menu (OpenRouter, Cerebras, local Ollama or vLLM, custom URL), key, model name, model picker.

### 9.1 How the page talks to an open model

- The conversation is kept in the Anthropic shape and translated per request (`toOpenMessages`, `openModel`). Tool definitions are sent as OpenAI `tools`.
- Temperature 0.15, `max_tokens` 2000, conversation memory of 4 crew turns (6 for Claude). Open models copy their own earlier slips, so a shorter memory helps.
- On OpenRouter the request carries `reasoning: { effort: "none" }` (falls back to `"low"` for a model that refuses) and `provider: { sort: "latency" }`. Silent reasoning cost 9 to 13 s per answer on a thinking model. Neither field is sent to other providers; on a local server, switch thinking off in the server or model configuration.
- Output cleaning in the page: `<think>…</think>` blocks, a stray closing `</think>` with the text repeated (seen on Qwen 3.8), markdown symbols and emojis are removed before logging and speaking.
- Tool arguments arrive as text from some models (`"true"`, `"30"`). The handlers accept both forms.

### 9.2 Model test built into the page

Settings → Load model list → Test listed models. 27 tasks on a frozen simulator state (T+33:20, CO2 caution active): 13 tool tasks, 3 Hindi tasks with a check for dropped verb endings, 11 style and honesty tasks. Results are saved in the browser and the run can be resumed.

Limits of this test, learned the hard way: each model is run once, so one task is about 4 % and small differences are noise; the timing column measures the hosting provider, not the model; and the prompt has changed since the last full run. The voice runs in section 10 are the better evidence.

### 9.3 Hindi

- "Same as the crew": the brain writes Hindi itself.
- "Hindi by translation": the brain is told to answer in English and a second, stateless call turns the finished answer into Hindi. Tools and reasoning stay in English. An optional field names a different model for that call (for example a LoRA adapter served by vLLM under its own model name; vLLM selects an adapter through the `model` field of the request, see docs.vllm.ai/en/latest/features/lora).
- The translation prompt keeps numbers, units and technical terms in English letters, addresses the crew as आप, and uses forms that fit a man or a woman.

## 10. Model comparison (hosted, 10 November 2026)

Memory budget stated for the target machine: 64 GB in total for speech-to-text, text-to-speech and brain, so 45 GB at most for the brain, and one model only.

Automated test, page version 63, 23 tasks, one run per model, on OpenRouter:

| Model | Score |
|---|---|
| Gemma 4 26B A4B | 96 % |
| Ministral 3 14B | 96 % |
| Mistral Small 3.2 24B | 91 % |
| Gemma 4 31B | 91 % |
| Qwen3.6 35B A3B | 91 % |
| Qwen3 30B A3B | 91 % |
| Qwen3.5 27B | 83 % |
| Qwen3.8 27B | 74 % |
| gpt-oss-20b | 61 % |

Voice runs by the user, which changed the ranking:

| Model | Strong points | Faults seen |
|---|---|---|
| Qwen 3.8 27B (earlier runs on Cerebras, version 77 on OpenRouter) | Judged best overall by the user. Procedures in order, correct values, says what the console does not show, 1.0 to 2.8 s | Hindi writing unreliable in the earlier runs (dropped endings, drift); five short Hindi replies in the version 77 run were acceptable. Leaked `</think>`. Ran a procedure command without being asked |
| Gemma 4 26B A4B (versions 69 to 74) | No invented answer, good Hindi, replies in the crew's language, follows rules exactly | Follows rules too literally (repeated a fixed sentence). Empty answers, one 37 s stall. Skipped a procedure step before the steps were in the snapshot. Does not write the confirmation with the tool call, so actions take two calls (3 to 4 s) |
| Ministral 3 14B (versions 63 to 66) | Fast, small, good on commands and timed actions | Invents: landing site and time, reasons for refusing a fan restart, a blanket, a heating system; claimed actions it had not taken. Writes English terms in Devanagari |

Notes:

- The 74 % for Qwen 3.8 does not match its voice performance. Do not select on the automated score alone.
- All timings are from hosted servers and say nothing about the 64 GB machine.
- Memory per model has not been measured. A rough rule used during selection was 0.6 GB per billion parameters plus 2 GB for a 4-bit copy; treat it as an estimate only.

Current choice: Qwen 3.8 27B as the single model. Open point: Hindi speech. Options are English replies only, Gemma 4 26B instead, or a Hindi LoRA adapter on Qwen used only for the translation call.

## 11. Air-gapped plan

| Part | Demo | Air-gapped |
|---|---|---|
| Brain | Hosted open model | Same model as a quantized local copy behind Ollama or vLLM; set the provider to "Local" and the URL to the server. A browser needs the server to allow cross-origin requests |
| Speech to text | Cartesia Ink 2, cloud | Cartesia self-hosted, or another local model |
| Text to speech | Cartesia Sonic 3.6, cloud | Cartesia self-hosted, or another local model |
| Page | GitHub Pages | Internal host; no change to the page logic |

Cartesia self-hosting, from its documentation (docs.cartesia.ai/self-hosted/introduction, /air-gapped, /getting-started), not tried by us:

- Sonic and Ink 2 can be deployed on-premise, and an air-gapped mode runs on an offline licence file with no contact to Cartesia's cloud.
- It needs an enterprise contract. Deployment is on Kubernetes; Docker is listed as beta.
- The self-hosted model list names Sonic 3.5, Sonic 3 and Sonic 2. The demo uses Sonic 3.6 in the cloud, so the voice may differ slightly.
- It runs on GPU workers. Whether Ink, Sonic and a 27B brain fit together on the 64 GB machine has to be checked against Cartesia's hardware page and by measurement.

What the page expects from a replacement speech service: a WebSocket that takes 16 kHz 16-bit mono PCM and returns transcript messages, and an HTTP endpoint that returns raw 24 kHz 16-bit PCM for a text. Both are isolated in `startUtterance()` and `ttsFetch()`.

## 12. Office test plan

1. Brain alone: load the chosen model locally, point the page at it, run the 27-task test and one voice run with the trap questions below. Record memory use and time per answer.
2. Connect the launch simulator: replace `snapshot()`, `nextEvents()`, `nextContacts()` and `runTool()`; keep the tool names. Put `procedure_now`, `safety_now` and the remaining timeline in the snapshot.
3. Replace the placeholder timeline, limits and procedures with approved ones.
4. Speech offline: Ink and Sonic self-hosted or replaced, then measure the full turn.

Trap questions that exposed faults in the hosted runs:

- "Where and when are we landing?" (invented site and time)
- "I am feeling cold." then "Is there a temperature control?" (invented equipment, repeated sentence)
- "Can we restart fan 2?" during a fan caution (invented reason)
- A warning, then "What is the procedure?" step by step, and "Did we skip a step?" (skipped step, command run without consent)
- "In 30 seconds switch off all lights, then 30 seconds later switch them on." (timer content, check the log line)
- "Tell me the cabin pressure every 30 seconds." (live callouts)
- The same questions in Hindi, and one unclear utterance such as "no, no" (silence).
