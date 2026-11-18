# 0009. Receipt pages: photos through the app, OCR requested once, live refreshes

Status: accepted, with the first receipt pages.

## Context

The app holds a few hundred receipts (about 300 loaded from the ingest set, 1.1 GB of photos) and gets
more from the browser. The owner needs to see them, open one, upload new ones and have them read by OCR,
which runs in Sidekiq with a local model, one receipt at a time, for seconds to minutes per receipt.
Three infrastructure questions came up: how photos reach the browser, how OCR is queued without being
queued twice, and how an open page learns that a job in another process finished.

## Decision

### Photos are served by an app controller, as resized JPEG copies

`Receipts::PhotosController` serves `/receipts/:receipt_id/photos/:attachment_id/(thumb|page|full)`
behind the same sign-in as every page. Rails' own Active Storage routes stay undrawn (they skip
sign-in, see 0002). The thumbnail and the reading size are Active Storage variants (libvips), made on the
first request and kept; every copy is a JPEG, so a HEIC original shows in every browser. The type sent
comes from an allow-list, and the browser may cache a photo privately for a day.

Rejected: signed, expiring blob URLs (they work without a session for as long as they last, and the
routes would have to be drawn); converting every photo to JPEG at upload (the original is the evidence
and the fingerprint is defined on its bytes).

### OCR is requested through one service, recorded in a column

`Receipts::RequestOcr` is the only code that queues `ReceiptOcrJob`. It claims the receipts by setting
`receipts.ocr_requested_at` under a row lock, only where it is nil, and the job clears it when it starts.
The column also authorises reading a `failed` or `extracted` receipt again, so a stray duplicate job
cannot replace a result nobody asked to replace.

Rejected: checking Sidekiq's queues for a job with the same argument (racy, and slow with hundreds of
jobs queued); a Redis lock with an expiry (lost with Redis, invisible in the database, and the right
expiry is unknowable when a "Read all" may take hours); a new `queued` status (it would widen a status
that the ledger rules and the receipt load depend on, for what is a transient fact).

Jobs are pushed one by one: Sidekiq's bulk push (`perform_all_later`) does not mark its jobs as
enqueued, so the service could not tell success from failure.

### Live pages are Turbo refreshes over Action Cable

The receipt page and the list subscribe to signed Turbo streams. `Receipts::LiveUpdate`, called
explicitly by the job and the services (they write with `update_columns`, so model callbacks would miss
changes), broadcasts a Turbo "refresh" with morphing after each commit. Action Cable uses the Redis
adapter already in place, so a broadcast from the Sidekiq process reaches the web server.

Rejected: replacing parts of the page with rendered partials (Action Cable does not keep the order of
messages, and a fast failure left a stale "Reading" badge in testing); polling (a request every few
seconds per open page, for events that happen once a minute at most).

Turbo drops a refresh that arrives while a visit is running; a small Stimulus controller
(`live_refresh_controller.js`) notices and asks for one more refresh afterwards.

The WebSocket accepts only a signed-in session, and the connection is identified by that session, so
signing out or a new password closes the ended sessions' sockets.

## Consequences

- The first visit to a page of 50 receipts makes up to 50 thumbnails (about 50 ms each); later visits
  read files. A HEIC photo's full-size JPEG copy is kept next to the original.
- Opening a receipt page that was never read queues OCR (the owner's choice), so receipt links opt out of
  Turbo's prefetch, and a request marked as a prefetch queues nothing.
- A refresh refetches the whole page. The review form (next) has to stay intact during one, or switch
  to narrower updates.
