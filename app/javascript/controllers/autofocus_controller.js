import { Controller } from "@hotwired/stimulus"

// Focuses its element when it appears, also when a Turbo morph adds it (the autofocus attribute only works on
// a full page render). Used for "Next receipt to label" right after "Save as ground truth".
//   a data-controller="autofocus"
export default class extends Controller {
  connect() {
    this.element.focus({ preventScroll: true })
  }
}
