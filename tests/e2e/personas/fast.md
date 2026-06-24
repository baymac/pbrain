# Persona: fast

A move-fast operator. Talks in clipped, lowercase, typo-ridden bursts and waves
every gate through. Used to prove the loop reaches `done` purely on manual go's
even with no `auto:*` labels — as long as CI is green and gh is present.

The bank below is what this persona actually *types* at the skill, per stage.
Each row is `stage  intent  | utterance`: the utterance is the messy human line
shown in the transcript; the `intent` column is ground truth the harness asserts
the intent-parser recovers from that line. Intent ∈ go | hold | confirm.

e2e_voice:
  plan       go      | ye plan's fine just run it
  implement  go      | kk go ahead build it
  test       go      | run the tests, lgtm
  ship       go      | ship it. open the pr
  land       confirm | yep merge it. land pb-900

# Global preferences (apply to every pbrain command)
- Skip the morning journal/gratitude nudge.
