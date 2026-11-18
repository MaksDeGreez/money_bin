import { Controller } from "@hotwired/stimulus"

// Keeps a live page current (docs/domain.md, "Live updates").
//
//   div data-controller="live-refresh" data-live-refresh-pending-value=(true while OCR is queued or running)
//     = turbo_stream_from @receipt
//
// Receipts::LiveUpdate broadcasts Turbo "refresh" actions. Some never take effect, so this asks for one
// more refresh in two cases:
// - a refresh arrived while a visit was running: Turbo drops it, and nothing asks again (an OCR job that
//   finishes during the "Reading" refresh would leave "Reading" on the page);
// - the stream (re)connected while the page shows OCR as queued or running: whatever was broadcast before
//   the subscription (a fast job right after an upload, a cable that dropped while the laptop slept, a
//   page restored from Turbo's cache by the back button) was missed.
// At worst that is one extra request; the page then shows what the database holds.
//
// The timestamps live in the module, not in the controller: a morph may reconnect the controller in the
// middle of the visit it has to watch, and a reconnect refresh is asked at most every few seconds, so a
// refresh can never set off another one.
let visitStartedAt = 0
let lastRefreshAt = 0
let lastReconnectRefreshAt = 0
let listening = false

const RECONNECT_REFRESH_GAP_MS = 5000

function refresh() {
  // turbo:load fires before Turbo forgets the finished visit; ask after it has.
  setTimeout(() => window.Turbo?.session.refresh(document.baseURI, { method: "morph", scroll: "preserve" }), 0)
}

function listen() {
  if (listening) return
  listening = true

  document.addEventListener("turbo:visit", () => { visitStartedAt = performance.now() })
  document.addEventListener("turbo:before-stream-render", (event) => {
    if (event.target.getAttribute("action") === "refresh") lastRefreshAt = performance.now()
  })
  document.addEventListener("turbo:load", () => {
    if (lastRefreshAt <= visitStartedAt) return

    lastRefreshAt = 0
    if (document.querySelector("[data-controller~='live-refresh']")) refresh()
  })
}

export default class extends Controller {
  static values = { pending: Boolean }

  connect() {
    listen()
    // turbo-rails sets `connected` on its stream source once the subscription is confirmed.
    this.observer = new MutationObserver((records) => {
      if (records.some((record) => record.target.hasAttribute("connected"))) this.connected()
    })
    this.observer.observe(this.element, { subtree: true, attributes: true, attributeFilter: ["connected"] })
  }

  disconnect() {
    this.observer?.disconnect()
  }

  connected() {
    if (!this.pendingValue) return

    const now = performance.now()
    if (now - lastReconnectRefreshAt < RECONNECT_REFRESH_GAP_MS) return

    lastReconnectRefreshAt = now
    refresh()
  }
}
