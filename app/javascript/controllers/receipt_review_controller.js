import { Controller } from "@hotwired/stimulus"

// The receipt review form's own behaviour (receipts/_review):
// - the kind select shows the card-slip parts (one category, card digits) or the items, without a request;
//   the server decides what a save does with each (Receipts::Review);
// - "Use the QR value" copies the QR ground truth into its field (the QR columns are never written);
// - "Use" on an item takes its suggested category, and "Accept suggestions" takes every suggestion at or
//   above the typed confidence for items that have no category yet (never replacing a chosen one).
// - "Fill the form from the tax-service record" replaces the header fields and the item rows with the
//   record's (data-receipt-review-fill-value, prepared by the server in the form's own formats), as unsaved
//   edits, and sets the hidden filled_from field, so a save records that the record pre-filled the form.
//   The rows come without categories, for the person to choose. Nothing is saved until the person saves.
// - "Book as": the account select is enabled only while "A new expense" is chosen, so the account is sent only
//   with it (a disabled select is not submitted; the server sends it to the booking only on that choice anyway).
// Taking a suggestion sets the row's category select and fires "change", like a choice by hand: the
// server then marks the item accepted_by_user.
const FILL_QUESTION = "Replace the fields and items in this form with the tax-service record? Nothing is saved until you save."

export default class extends Controller {
  static targets = ["kind", "slipOnly", "itemsOnly", "threshold", "suggestionStatus", "filledFrom", "fillStatus", "booking",
    "bookingAccount"]
  static values = { fill: Object }
  static outlets = ["line-items"]

  fillFromRecord() {
    const { fields, items } = this.fillValue
    if (!fields || !this.hasLineItemsOutlet || !window.confirm(FILL_QUESTION)) return

    for (const [id, value] of Object.entries(fields)) {
      const input = document.getElementById(id)
      if (!input) continue
      input.value = value
      input.dispatchEvent(new Event("input", { bubbles: true }))
    }
    this.kindChanged()
    this.lineItemsOutlet.replaceRows(items || [])
    if (this.hasFilledFromTarget) {
      this.filledFromTarget.value = "dps_xml"
      this.filledFromTarget.dispatchEvent(new Event("change", { bubbles: true }))
    }
    if (this.hasFillStatusTarget) {
      const count = (items || []).length
      this.fillStatusTarget.textContent = `Filled from the tax-service record: ${count} item${count === 1 ? "" : "s"}. ` +
        "Choose their categories, check them against the photo and save."
    }
  }

  bookingChanged(event) {
    if (!this.hasBookingAccountTarget) return

    const newExpense = event.target.value === "new" && event.target.checked
    this.bookingAccountTarget.disabled = !newExpense
    if (newExpense) this.bookingAccountTarget.focus()
  }

  kindChanged() {
    const slip = this.kindTarget.value === "card_slip"
    this.slipOnlyTargets.forEach((element) => { element.hidden = !slip })
    this.itemsOnlyTargets.forEach((element) => { element.hidden = slip })
    this.dispatch("kind")
  }

  // The value is read as text from data-qr-value: a Stimulus param would be JSON-parsed into a Number.
  copyQr(event) {
    const { qrValue, qrField } = event.currentTarget.dataset
    const input = document.getElementById(qrField)
    if (!input || qrValue === undefined) return

    input.value = qrValue
    input.dispatchEvent(new Event("input", { bubbles: true }))
    input.focus()
  }

  useSuggestion(event) {
    const row = event.target.closest("[data-suggestion-id]")
    if (row) this.takeSuggestion(row)
  }

  // "Use" under a card slip's category: take the slip's own suggestion.
  useSlipSuggestion(event) {
    const field = event.target.closest("[data-slip-suggestion-id]")
    const select = field && this.categorySelect(field)
    if (!select || !field.dataset.slipSuggestionId) return

    select.value = field.dataset.slipSuggestionId
    select.dispatchEvent(new Event("change", { bubbles: true }))
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
