# QA notes — History mode, AI features, themes (2026-11-13)

Notes from a hands-on pass. These are findings to go over together later, not decisions yet.
More may be added after the AI features pass.

## History mode

1. **No obvious way out of History.** When a version is selected in History, the only way back to
   normal editing is clicking Outline, Files, or Basics. That will confuse people.
   - Add an **Exit** button in the left sidebar, to the right of the "History" title.
   - Style it like the existing button in the Files tab (the desktop one), placed on the right side.
   - Exit probably just returns to Outline.

2. **Open the left panel when something lands in History.** The first time something is added to
   History — and whenever an AI action such as Rewrite adds a version — the left sidebar should
   open and show History, so people learn it is there.

3. **"Double entry" — really a broken flow for adding a manual version.** Repro: select the word
   "gentle" → Add to History. The History panel shows only "Click a highlighted passage to see its
   versions." Click "gentle" → the list shows **two** "gentle" entries, though only the original was
   added. Confusing, and it reveals the deeper problem:
   - Adding to History snapshots the original, but there is no way to write the alternative *inside*
     History. To try "dangerous" instead, you must leave to Outline, edit the text, Add to History
     again, then come back to History. Broken round trip.
   - If you just edit the word without adding first, the original ("gentle") is never recorded.
   - **Proposed flow:** the first entry is the original ("gentle"). Instead of a duplicate second
     entry, show a **＋ "Add a replacement"** row. Clicking it makes an editable field where you type
     the alternative — a word, a few words, a sentence, anything. Below it, another ＋ to add another
     alternative. You can then toggle between versions (←/→) right there without leaving History.
   - Open question for later: whether the duplicate is a separate bug (current text listed alongside
     its identical snapshot) — check once the new flow is designed.

4. **Footer hint is easy to miss and centered.** The bottom text ("Click to select · ←/→ switch
   versions · Esc close") gets lost. Keep it at the bottom, but **left-align** it so it lines up with
   the other small text shown when History is empty.

4b. **Wrong cursor over highlighted passages.** In History mode ("Click a highlighted passage to
    see its versions"), hovering a highlighted passage shows the text I-beam. It should show the
    pointing-hand cursor, since the passage is clickable. Keep the I-beam over ordinary text.

4c. **Right-click menu in History shows formatting commands.** Title, Section, Bold, Italic,
    Code, Link, etc. still appear in the context menu while in History mode. They should be
    hidden there (History isn't for formatting).

4d. **Other History passages vanish when one is selected.** With three rewritten passages, clicking
    one dims everything else — including the other highlights — so there's no way to see what else
    is clickable; you end up clicking around blindly. Fix: when one passage is selected, the OTHER
    passages keep a visible (dimmed) highlight; hovering one brings it back to full strength;
    clicking it selects it and dims the rest the same way.

## Themes / Reading settings

5. **Quiet theme card disappears in Dark Mode.** In Dark Mode, when the current theme is Original
   (so Quiet has no blue selection outline), the Quiet card blends into the background. Give it a
   slightly lighter tone (or a subtle border) in dark chrome so it stands out when unselected.

6. **Per-theme edits should persist.** Today: edit Original (font size, line height), switch to
   Quiet, switch back to Original → edits are reset. Wanted: each theme keeps the user's own edits
   when you switch away and back. "Reset to Default" (already at the bottom) stays the way back to
   the theme's built-in values.

## Fonts

7. **"Writing" font group label is wrong.** In the font picker, the group labeled "Writing" contains
   Monospaced, which reads as a code font. Rename the group — not "Code" (other fonts may be added
   there later) and not "Writing". Name still to be decided; brainstorm options when we pick this up.

## AI features

8. **API key vs. subscription is a blocker for many people.** People who already pay for Claude
   Pro/Max or ChatGPT Plus don't want a second, per-use API account. Checked 2026-11-13:
   - **ChatGPT — possible.** OpenAI's "Sign in with ChatGPT" (developers.openai.com/siwc) lets
     Plus/Pro users spend their plan allowance in third-party apps. Open-source and locally run apps
     can use it; paid or remotely hosted apps join a waitlist via the interest form. Lineform is free
     and local but source-available (not OSI open source) and on the App Store, so file the interest
     form to confirm eligibility. Technical fit: browser sign-in with a 127.0.0.1 loopback callback
     (sandbox needs the network-server entitlement), then the Responses API with stream=true and
     store=false. The app must show "Using ChatGPT plan" + a "Manage usage" link.
   - **Claude — not possible.** Anthropic forbids using Free/Pro/Max sign-in in third-party apps
     (enforced since Jan 2026, explicit in terms Feb 2026). API key only.
   - **Gemini — not possible.** No sanctioned program for Google AI Pro/Ultra in third-party apps;
     API key only.
   - Also worth weighing: Apple's on-device model (no key, no account; spec currently rules it out),
     local models via "Other", and Writing Tools (already works, can use a signed-in ChatGPT account).
   - **Decision (2026-11-13):** keep API keys only for now. Sign in with ChatGPT is deferred to
     later; no interest form submitted yet.

9. **Security: close the `.local` plain-http gap for "Other".** Key storage and transport were
   reviewed on `feature/bring-your-own-ai` (2026-11-13) and are sound: Keychain only, not synced,
   read only at action time, fixed HTTPS endpoints, key in a header, redirects refused, nothing
   logged, `<redacted>` description. One gap: `AIEndpointValidation.allowsPlainHTTP` accepts
   `*.local`, so an "Other" server on another LAN device with a key set sends that key unencrypted
   over Wi-Fi. Fix: allow plain http only for loopback (`localhost`, `127.0.0.1`, `::1`), or allow
   `.local` only when no key is entered. Update `AIConnectionStoreTests` (the `printer.local` case)
   and the `.insecureAddress` message to match.

10. **Key-permission guidance in Connect Your AI.** People creating a key see choices like
    All / Restricted / Read only and don't know what Lineform needs. Add one short line of
    per-provider guidance on each provider page (localized):
    - **ChatGPT (OpenAI):** "Choose Restricted, set Model capabilities to Request, and leave
      everything else off." Read only will NOT work — Lineform has to send requests. (OpenAI's UI
      quirk: "Write" on Model capabilities can fail with "missing model.request"; "Request" works.)
    - **Claude (Anthropic):** the key dialog has Name, Scope (workspace), Linked account, and
      Expires — no per-endpoint permissions. Guidance: "Make a key just for Lineform, and set a
      monthly spend limit in the Console." If the writer sets an expiry, the key stops working on
      that date; Lineform then shows "The key wasn't accepted" — consider wording that hints at
      expiry.
    - **Google (AI Studio):** no scopes in AI Studio. Same guidance as Claude; optionally, in
      Google Cloud the key can be restricted to the Generative Language API.
    - All pages: name the key "Lineform" and set a spending limit — that caps the worst case.
    - Re-verify the OpenAI wording against the live key dialog before shipping (its labels change).

11. **Which model each provider uses.** Today it is fixed in code (`AIProvider.defaultModel` on
    `feature/bring-your-own-ai`), mid-tier, not the most expensive: Claude → `claude-sonnet-5-5`,
    ChatGPT → `gpt-5-mini`, Google → `gemini-2.5-flash`. Only "Other" has a model field. Writers
    can't see or change the model for the big three. To discuss:
    - Show the model name on the provider page so people know what they're paying for.
    - Possibly a small optional choice (e.g. "Faster & cheaper" vs "Higher quality") without
      cluttering the main path — e.g. Claude Haiku 5.5 vs Sonnet 5.5.
    - Re-check the Google and OpenAI defaults are still current models before shipping.
    - **Direction (2026-11-13, revised): keep the three providers on the same tier.**
      | Tier | Claude | ChatGPT | Google |
      |---|---|---|---|
      | Budget (default) | Haiku 5.5 `claude-haiku-5-5` $0.10/$0.50 | GPT-6 Luna `gpt-6-luna` $0.10/$0.50 | Gemini 3.5 Flash-Lite $0.30/$2.50 (or 3.1 Flash-Lite $0.25/$1.50) |
      | Mid ("Higher quality") | Sonnet 5.5 `claude-sonnet-5-5` $2/$10 | GPT-6.1 Terra `gpt-6.1-terra` $1/$5 | Gemini 3.8 Flash $0.75/$3.75 → $1.50/$7.50 on 2027-01-01 |
      - Writing-quality data is thin. LMArena creative writing (third-party snapshots, Nov 2026):
        Luna ~1410, Gemini 3.5 Flash-Lite ~1437, Sonnet 5.5 ~1468, Gemini 3.8 Flash ~1488;
        no score found for Haiku 5.5, Terra, or 3.1 Flash-Lite. A ~60-point gap means readers
        prefer the mid model about 58% of the time — real but modest, and measured on creative
        writing, not edits.
      - Lean: Budget tier as the default for all three; the mid tier becomes the optional
        "Higher quality" choice. Before shipping, run the same handful of real passages through
        each budget model and read them side by side.
      - Verify exact Gemini model IDs and that `gpt-6-luna` works on chat completions.

12. **Let writers choose the model tier (decided 2026-11-13).** On each provider page in
    Connect Your AI, below the key field, a small two-option picker:
    - **Standard — the default** — Haiku 5.5 / GPT-6 Luna / Gemini Flash-Lite (lowest-cost tier).
    - **Higher quality** — Sonnet 5.5 / GPT-6.1 Terra / Gemini 3.8 Flash.
    - Show the actual model name under each option. **No cost captions or warnings** — the owner's
      call: people choose for themselves; pricing is the provider's to explain.
    - Changeable any time without re-entering the key. Stored per provider in UserDefaults (not
      secret); persisted values are raw identifiers, never localized. "Other" keeps its free-text
      model field.
    - Model IDs live in one table (`AIProvider`), so updating to a newer model is a one-line change.

13. **AI review UI — needs a rework (from first real use, 2026-11-13).**
    - **"Rewriting with ChatGPT…" progress card is centered.** Keep the content (spinner,
      "Rewriting with ChatGPT", "Esc to cancel" — all liked), but move it to the **bottom-right
      corner** and give it the exact same design as the "Make Lineform your default" card: same
      size, corner radius, type sizes, padding, and the close X in the same position.
    - **Accept All / Reject All strip is too wide.** Long bar with lots of dead space along the
      bottom. Same treatment: a bottom-right card matching the default-app card.
    - **Bug: one sentence rewrite was split into three changes.** Selected the sentence "…through
      wise man at their end, no, that darkness is right…" and chose Rewrite; the review broke it
      into three separate pills. A rewrite of one sentence should review as one change (or the
      split should be much less eager).
    - **The pills look bad and are hard to use.** Small, hard to click; some are greyed and some
      aren't (unclear why); one almost overlaps the text; hovering shows the I-beam instead of
      the pointing hand. Unsure pills are the right control at all — may need real buttons.
      **Next step: mock up a few alternatives to compare** before changing code.
    - **What the screenshots showed (2026-11-13):**
      - Progress card ("Rewriting with ChatGPT… / Esc to cancel", X at right) floats bottom-center
        over the last lines of text, covering them.
      - Review bar ("1 of 3", Reject All, Accept All) is also bottom-center and wide, covering
        text the same way.
      - The one-line rewrite "Though wise men, at their end know dark is right," came back as
        three inline pills: a comma after "men", a comma after "end", and "dark" → "that
        darkness" (old word greyed, new words inline). That is a word-level diff, so one rewrite
        becomes three decisions. The bold pill is the current "1 of 3"; the grey ones are the
        others. That's why some look greyed, but nothing explains it on screen.
      - The pills sit in the text line at the same height as the letters, crowding the words next
        to them ("darkness ⓥ|ⓧis right").
      - The context menu over a selection lists Add to History / Rewrite / Proofread / Mark plus
        the full formatting block (Title ⌘1, Section ⌘2, Bold, Italic, Code, Bulleted List,
        Link). In History mode the formatting block should be hidden (item 4c).
