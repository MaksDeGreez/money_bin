import { Controller } from "@hotwired/stimulus"

// Keeps a person's typing safe in a long form (the receipt review form, manual entry), and its keyboard
// shortcuts.
//
//   form data-controller="form-guard" data-form-guard-dirty-value="false" data-form-guard-errors-value="false"
//     button data-form-guard-target="save" / "groundTruth" / "accept";  [data-form-guard-target="notice"] hidden
//
// - Unsaved changes: any input or change in the form (or a row added or removed) marks it dirty; a server
//   that refused a save renders it dirty already, since the values on screen are not saved.
// - While dirty, a live refresh of the page (Receipts::LiveUpdate, a Turbo "refresh" stream) is skipped
//   rather than morphing the form back to the stored values; the notice says the page has news. The live
//   refresh controller asks for no refresh either (it reads the data-unsaved-changes flag on <html>). The
//   server still refuses a save from a stale page (the form's lock_version). A refresh already on its way when
//   the person starts typing is stopped when it renders: the form is not morphed while dirty. The form's own
//   submission is never held back: a refused save's response (422, 409) renders, with its errors and the
//   typed values, and focus goes to the first field marked invalid.
// - While a submission is on its way the form is inert, so nothing typed then can be lost to the response.
// - Leaving the page while dirty asks first (a Turbo visit, and closing or reloading the tab). So does sending
//   another form of the page ("Undo the acceptance", "Read again"), before it reaches the server: its redirect
//   would only ask once the server had acted. A yes drops the unsaved changes once that request really starts (after
//   Turbo's own confirmation, which may still say no), so its response can render; a request that fails puts the
//   guard back.
// - Enter never submits the form by accident; Ctrl+S (Cmd+S) clicks Save, Ctrl+Shift+S (Cmd+Shift+S) clicks
//   Save as ground truth and Ctrl+Enter (Cmd+Enter) clicks Accept, when the form has them and they are
//   enabled. Missing Shift on the ground-truth shortcut only saves, which is harmless.
// - After a refused save, focus goes to an element marked data-form-guard-focus (the confirmation of
//   replacing ground truth), else to the first field marked invalid.
const LEAVE_MESSAGE = "Leave this page? Your changes are not saved."

export default class extends Controller {
  static targets = ["save", "groundTruth", "accept", "notice"]
  static values = { dirty: Boolean, errors: Boolean }

  connect() {
    this.submitting = false
    this.listeners = [
      [document, "turbo:before-visit", (event) => this.beforeVisit(event)],
      [window, "beforeunload", (event) => this.beforeUnload(event)],
      [document, "turbo:before-stream-render", (event) => this.beforeStreamRender(event)],
      [document, "turbo:before-morph-element", (event) => this.beforeMorph(event)],
      [document, "turbo:render", () => this.rendered()],
      [document, "turbo:submit-start", (event) => this.submitStart(event)],
      [document, "turbo:submit-end", (event) => this.submitEnd(event)],
      [document, "keydown", (event) => this.shortcut(event)],
      [this.element, "input", () => this.markDirty()],
      [this.element, "change", () => this.markDirty()],
      [this.element, "line-items:changed", () => this.markDirty()],
      [this.element, "keydown", (event) => this.preventImplicitSubmit(event)],
      [this.element, "submit", () => { this.submitting = true }],
      // Captured on the document, so it runs before Turbo's own submit handling (and its confirmation).
      [document, "submit", (event) => this.otherFormSubmit(event), true]
    ]
    this.listeners.forEach(([target, name, handler, capture]) => target.addEventListener(name, handler, capture === true))
  }

  // On connect and when a refused save's response is morphed in (the controller stays connected then).
  errorsValueChanged() {
    if (this.errorsValue) this.focusFirstInvalid()
  }

  disconnect() {
    this.listeners.forEach(([target, name, handler, capture]) => target.removeEventListener(name, handler, capture === true))
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

  otherFormSubmit(event) {
    if (event.target === this.element || !this.guarding) return
    if (window.confirm(LEAVE_MESSAGE)) {
      this.leavingWith = event.target
    } else {
      event.preventDefault()
      event.stopImmediatePropagation()
    }
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
    else if (event.target === this.leavingWith) this.dirtyValue = false
  }

  submitEnd(event) {
    if (event.target === this.leavingWith) {
      this.leavingWith = null
      if (!event.detail.success) this.dirtyValue = true
      return
    }
    if (event.target !== this.element) return
    this.submitting = false
    this.element.inert = false
    if (event.detail.success) this.dirtyValue = false
    // A refused save that came back renders next; a request that never got an answer renders nothing.
    else if (event.detail.fetchResponse) this.ownResponse = true
  }

  // Any morph of the form while it is dirty is a refresh (a live one, or one already on its way when the
  // typing started), except the response to the form's own refused save, which carries the typed values.
  beforeMorph(event) {
    if (event.target === this.element && this.dirtyValue && !this.ownResponse) event.preventDefault()
  }

  rendered() {
    if (!this.ownResponse) return
    this.ownResponse = false
    if (this.errorsValue) this.focusFirstInvalid()
  }

  focusFirstInvalid() {
    const target = this.element.querySelector("[data-form-guard-focus]") || this.element.querySelector("[aria-invalid='true']")
    target?.focus()
  }

  shortcut(event) {
    if (!(event.ctrlKey || event.metaKey) || event.altKey) return

    const s = event.key === "s" || event.key === "S"
    let button = null
    if (s && event.shiftKey) button = this.hasGroundTruthTarget ? this.groundTruthTarget : null
    else if (s) button = this.hasSaveTarget ? this.saveTarget : null
    else if (event.key === "Enter" && !event.shiftKey) button = this.hasAcceptTarget ? this.acceptTarget : null
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
