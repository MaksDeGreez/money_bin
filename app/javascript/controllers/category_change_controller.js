import { Controller } from "@hotwired/stimulus"

// The "Change" form of a transaction's categories (transactions/_categories_form), loaded into the Turbo Frame next
// to its "Change" link:
//
//   form data-controller="category-change" data-category-change-return-value="<the Change link's id>"
//        data-action="keydown->category-change#keydown"
//
// - it opens with the focus in the first picker (Enter in a picker saves, once no list is open);
// - Escape (when no picker list is open: the picker closes its own first) or "Cancel" empties the frame, and the
//   focus goes back to "Change". After a save the answer focuses "Change" itself (the autofocus controller on the
//   replaced row's link, or on the transaction page's).
export default class extends Controller {
  static values = { return: String }

  connect() {
    requestAnimationFrame(() => this.element.querySelector("[role='combobox']")?.focus())
  }

  keydown(event) {
    if (event.key !== "Escape" || event.defaultPrevented) return

    event.preventDefault()
    this.close()
  }

  close() {
    const frame = this.element.closest("turbo-frame")
    const id = this.returnValue
    if (frame) {
      frame.removeAttribute("src")
      frame.replaceChildren()
    }
    document.getElementById(id)?.focus()
  }
}
