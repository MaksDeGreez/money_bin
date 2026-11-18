import { Controller } from "@hotwired/stimulus"

// Keeps a person's typing safe in a long form (the receipt review form, manual entry), and its keyboard
// shortcuts.
//
//   form data-controller="form-guard" data-form-guard-dirty-value="false" data-form-guard-errors-value="false"
//     button data-form-guard-target="save" / "accept";  [data-form-guard-target="notice"] hidden
//
// - Unsaved changes: any input or change in the form (or a row added or removed) marks it dirty; a server
//   that refused a save renders it dirty already, since the values on screen are not saved.
// - While dirty, a live refresh of the page (Receipts::LiveUpdate, a Turbo "refresh" stream) is skipped
//   rather than morphing the form back to the stored values; the notice says the page has news. The live
//   refresh controller asks for no refresh either (it reads the data-unsaved-changes flag on <html>). The
//   server still refuses a save from a stale page (the form's lock_version). The form's own submission is
//   never held back: a refused save's response (422, 409) must render, with its errors and the typed values.
// - While a submission is on its way the form is inert, so nothing typed then can be lost to the response.
// - Leaving the page while dirty asks first (a Turbo visit, and closing or reloading the tab).
// - Enter never submits the form by accident; Ctrl+S (Cmd+S) clicks Save and Ctrl+Enter (Cmd+Enter) clicks
//   Accept, when the form has them and they are enabled.
// - After a refused save, focus goes to the first field marked invalid.
const LEAVE_MESSAGE = "Leave this page? Your changes are not saved."

export default class extends Controller {
  static targets = ["save", "accept", "notice"]
  static values = { dirty: Boolean, errors: Boolean }

  connect() {
    this.submitting = false
    this.listeners = [
      [document, "turbo:before-visit", (event) => this.beforeVisit(event)],
      [window, "beforeunload", (event) => this.beforeUnload(event)],
      [document, "turbo:before-stream-render", (event) => this.beforeStreamRender(event)],
      [document, "turbo:submit-start", (event) => this.submitStart(event)],
      [document, "turbo:submit-end", (event) => this.submitEnd(event)],
      [document, "keydown", (event) => this.shortcut(event)],
      [this.element, "input", () => this.markDirty()],
      [this.element, "change", () => this.markDirty()],
      [this.element, "line-items:changed", () => this.markDirty()],
      [this.element, "keydown", (event) => this.preventImplicitSubmit(event)],
      [this.element, "submit", () => { this.submitting = true }]
    ]
    this.listeners.forEach(([target, name, handler]) => target.addEventListener(name, handler))
  }

  // On connect and when a refused save's response is morphed in (the controller stays connected then).
  errorsValueChanged() {
    if (this.errorsValue) this.element.querySelector("[aria-invalid='true']")?.focus()
  }

  disconnect() {
    this.listeners.forEach(([target, name, handler]) => target.removeEventListener(name, handler))
    delete document.documentElement.dataset.unsavedChanges
  }

  dirtyValueChanged() {
    if (this.dirtyValue) document.documentElement.dataset.unsavedChanges = "true"
    else delete document.documentElement.dataset.unsavedChanges
  }

  markDirty() {
    this.dirtyValue = true
  }

  get guarding() {
    return this.dirtyValue && !this.submitting
  }

  beforeVisit(event) {
    if (this.guarding && !window.confirm(LEAVE_MESSAGE)) event.preventDefault()
  }

  beforeUnload(event) {
    if (!this.guarding) return
    event.preventDefault()
    event.returnValue = ""
  }

  beforeStreamRender(event) {
    if (!this.dirtyValue || event.target.getAttribute?.("action") !== "refresh") return
    event.detail.render = () => {
      if (this.hasNoticeTarget) this.noticeTarget.hidden = false
    }
  }

  submitStart(event) {
    if (event.target === this.element) this.element.inert = true
  }

  submitEnd(event) {
    if (event.target !== this.element) return
    this.submitting = false
    this.element.inert = false
    if (event.detail.success) this.dirtyValue = false
  }

  shortcut(event) {
    if (!(event.ctrlKey || event.metaKey) || event.altKey || event.shiftKey) return

    let button = null
    if (event.key === "s" || event.key === "S") button = this.hasSaveTarget ? this.saveTarget : null
    else if (event.key === "Enter") button = this.hasAcceptTarget ? this.acceptTarget : null
    else return

    event.preventDefault()
    if (button && !button.disabled) this.element.requestSubmit(button)
  }

  preventImplicitSubmit(event) {
    if (event.key !== "Enter" || event.defaultPrevented || event.ctrlKey || event.metaKey) return
    const field = event.target
    if (field instanceof HTMLInputElement && !["submit", "button", "checkbox", "radio"].includes(field.type)) event.preventDefault()
  }
}
