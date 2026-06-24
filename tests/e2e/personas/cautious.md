# Persona: cautious

A risk-averse operator. Hedges and stalls — vague "not yet"s rather than a clean
no. Approves no gate without being sure, so any stage lacking its `auto:<stage>`
label parks. Used to prove the park-and-resume path is durable for every gate.

The bank below is what this persona actually *types* at the skill, per stage.
Each row is `stage  intent  | utterance`: the utterance is the messy human line
shown in the transcript; the `intent` column is ground truth the harness asserts
the intent-parser recovers from that line. Intent ∈ go | hold | confirm.

e2e_voice:
  plan       hold    | mm hold on lemme think about this
  implement  hold    | eh not yet, dont build it til i look
  test       hold    | idk wait
  ship       hold    | no dont open a pr yet
  land       hold    | stop, not merging this rn

# Global preferences (apply to every pbrain command)
- Be terse. Skip the morning journal/gratitude nudge.
