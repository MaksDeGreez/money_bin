import { Controller } from "@hotwired/stimulus"

// Keeps a live page current (docs/domain.md, "Live updates").
//
//   div data-controller="live-refresh"
//     = turbo_stream_from @receipt
//
// Receipts::LiveUpdate broadcasts Turbo "refresh" actions. Turbo drops a refresh that arrives while a
// visit is still running (its own earlier refresh, for example), and nothing asks again: an OCR job that
// finishes during the "Reading" refresh would leave "Reading" on the page. This notes when a refresh
// arrived during a visit and, once that visit is done, asks for one more refresh if the page still has
// this controller. At worst that is one extra request; the page then shows what the database holds.
//
// The timestamps live in the module, not in the controller: a morph may reconnect the controller in the
// middle of the visit it has to watch.
let visitStartedAt = 0
let lastRefreshAt = 0
let listening = false

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
    if (!document.querySelector("[data-controller~='live-refresh']")) return
    // turbo:load fires before Turbo forgets the finished visit; ask after it has.
    setTimeout(() => window.Turbo?.session.refresh(document.baseURI, { method: "morph", scroll: "preserve" }), 0)
  })
}

export default class extends Controller {
  connect() {
    listen()
  }
}
