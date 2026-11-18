import { Controller } from "@hotwired/stimulus"

// The keyboard on the transactions list's uncategorised lines (docs/domain.md, "Transaction suggestions"):
//
//   div data-controller="review-queue" data-action="keydown@window->review-queue#keydown"
//     tr data-review-queue-target="row" tabindex="0"  (one per uncategorised line, with its form)
//
// - j / k anywhere on the page: the next / previous line; ArrowDown / ArrowUp too, once a line has the focus
//   (elsewhere they scroll the page as usual);
// - t: take the focused line's suggestion ("Take"); c: open its category picker;
// - after a line is saved, the focus moves on to the next line still waiting (the answer replaces the
//   transaction's rows, so the place is remembered before).
// Keys typed into a field (the picker, the threshold) are left alone.
export default class extends Controller {
  static targets = ["row"]

  keydown(event) {
    if (event.defaultPrevented || event.ctrlKey || event.metaKey || event.altKey) return
    if (event.target.closest("input, select, textarea, [contenteditable]")) return

    const row = event.target.closest("[data-review-queue-target='row']")
    switch (event.key) {
      case "j":
        this.move(row, 1, event)
        break
      case "k":
        this.move(row, -1, event)
        break
      case "ArrowDown":
        if (row) this.move(row, 1, event)
        break
      case "ArrowUp":
        if (row) this.move(row, -1, event)
        break
      case "t":
        if (row) this.press(row.querySelector("[data-review-queue-target='take']"), event)
        break
      case "c":
        if (row) this.press(row.querySelector("[data-review-queue-target='picker'] input"), event, "focus")
        break
    }
  }

  move(row, step, event) {
    const rows = this.rowTargets
    if (rows.length === 0) return

    const index = row ? rows.indexOf(row) : -1
    const next = rows[Math.min(Math.max(index + step, 0), rows.length - 1)]
    event.preventDefault()
    next.focus()
    next.scrollIntoView({ block: "nearest" })
  }

  press(element, event, action = "click") {
    if (!element) return

    event.preventDefault()
    element[action]()
  }

  // A line's form was submitted: focus the first waiting line after it once the answer has replaced the rows.
  advance(event) {
    const row = event.target.closest("[data-review-queue-target='row']")
    const rows = this.rowTargets
    const after = rows.slice(rows.indexOf(row) + 1).map((element) => element.id)
    const before = row?.id
    setTimeout(() => {
      const target = [before, ...after].map((id) => id && document.getElementById(id)).find(Boolean)
      target?.focus()
    }, 50)
  }
}
