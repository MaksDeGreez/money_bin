import { Controller } from "@hotwired/stimulus"

// The receipt review form's own behaviour (receipts/_review):
// - the kind select shows the card-slip parts (one category, card digits) or the items, without a request;
//   the server decides what a save does with each (Receipts::Review);
// - "Use the QR value" copies the QR ground truth into its field (the QR columns are never written);
// - "Use" on an item takes its suggested category, and "Accept suggestions" takes every suggestion at or
//   above the typed confidence for items that have no category yet (never replacing a chosen one).
// Taking a suggestion sets the row's category select and fires "change", like a choice by hand: the
// server then marks the item accepted_by_user.
export default class extends Controller {
  static targets = ["kind", "slipOnly", "itemsOnly", "threshold", "suggestionStatus"]

  kindChanged() {
    const slip = this.kindTarget.value === "card_slip"
    this.slipOnlyTargets.forEach((element) => { element.hidden = !slip })
    this.itemsOnlyTargets.forEach((element) => { element.hidden = slip })
    this.dispatch("kind")
  }

  copyQr({ params: { value, field } }) {
    const input = document.getElementById(field)
    if (!input) return

    input.value = value
    input.dispatchEvent(new Event("input", { bubbles: true }))
    input.focus()
  }

  useSuggestion(event) {
    const row = event.target.closest("[data-suggestion-id]")
    if (row) this.takeSuggestion(row)
  }

  acceptSuggestions() {
    const threshold = Number(this.thresholdTarget.value)
    if (!Number.isFinite(threshold)) return

    let taken = 0
    for (const row of this.element.querySelectorAll("[data-suggestion-id]")) {
      if (row.hidden || this.categorySelect(row)?.value) continue
      // The confidence as the page shows it, a whole percent, so "62%" passes a threshold of 62.
      if (Math.round(Number(row.dataset.suggestionConfidence) * 100) < threshold) continue

      this.takeSuggestion(row)
      taken += 1
    }
    if (this.hasSuggestionStatusTarget) {
      this.suggestionStatusTarget.textContent = taken === 0
        ? `No item without a category has a suggestion at ${threshold}% or more.`
        : `Took ${taken} suggestion${taken === 1 ? "" : "s"} at ${threshold}% or more. Save to keep them.`
    }
  }

  takeSuggestion(row) {
    const select = this.categorySelect(row)
    if (!select || select.value === row.dataset.suggestionId) return

    select.value = row.dataset.suggestionId
    select.dispatchEvent(new Event("change", { bubbles: true }))
  }

  categorySelect(row) {
    return row.querySelector("select[data-combobox-target='select']")
  }
}
