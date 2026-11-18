"""Receipt OCR pieces shared by every model backend.

- `prompt`: the instructions, the answer's JSON schema and `PROMPT_VERSION`.
- `parsing`: reads the model's text as JSON, with one repair pass.
- `postprocess`: plain code that turns the model's answer into a `Receipt`
  (decimal formats, quantity and discount lines, the total check).
- `images`: decodes, turns upright and scales down the uploaded photos.

A local and a hosted backend use the same pieces, so the two differ only in
the model that answers.
"""
