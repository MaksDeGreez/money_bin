import { Controller } from "@hotwired/stimulus"

// Editable rows of a form (the review form's items, manual entry's rows): add a row, remove a row, and the
// keyboard between rows.
//
//   section data-controller="line-items" data-action="keydown->line-items#keydown"
//     div data-line-items-target="body"     (the rows, each data-line-items-target="row")
//     template data-line-items-target="template"   (a new row; "NEW_ROW" in its field names)
//     button data-action="line-items#add" data-line-items-target="addButton"
//
// - Add: the template's row with a fresh key in place of NEW_ROW, focus on its first field.
// - Remove: a stored row (it has an id field) gets _destroy=1 and is hidden, so the save removes it; a new
//   row leaves the page. Focus moves to the row that took its place, else the one before, else "Add".
// - Enter in a row's field (one the combobox did not take): the last row adds a row; any other row moves to
//   the same field of the next row. Never a form submission.
// Each change dispatches "line-items:changed" (bubbling) for the totals and the unsaved-changes guard.
export default class extends Controller {
  static targets = ["body", "template", "row", "addButton"]

  connect() {
    this.counter = 0
  }

  add(event) {
    event?.preventDefault()
    const key = `${Date.now()}${this.counter++}`
    this.bodyTarget.insertAdjacentHTML("beforeend", this.templateTarget.innerHTML.replaceAll("NEW_ROW", key))
    this.focusField(this.visibleRows.at(-1), 0)
    this.changed()
  }

  remove(event) {
    const row = event.target.closest("[data-line-items-target~='row']")
    if (!row) return

    const index = this.visibleRows.indexOf(row)
    if (row.querySelector("input[type='hidden'][name$='[id]']")) {
      row.querySelector("[data-line-items-destroy]").value = "1"
      row.hidden = true
    } else {
      row.remove()
    }

    const rows = this.visibleRows
    const next = rows[index] || rows[index - 1]
    if (next) this.focusField(next, 0)
    else if (this.hasAddButtonTarget) this.addButtonTarget.focus()
    this.changed()
  }

  keydown(event) {
    if (event.key !== "Enter" || event.defaultPrevented || event.isComposing) return
    if (event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return

    const field = event.target
    if (!(field instanceof HTMLInputElement)) return
    const row = field.closest("[data-line-items-target~='row']")
    if (!row) return

    event.preventDefault()
    const rows = this.visibleRows
    const index = rows.indexOf(row)
    if (index === rows.length - 1) {
      this.add()
    } else {
      this.focusField(rows[index + 1], this.fields(row).indexOf(field))
    }
  }

  get visibleRows() {
    return this.rowTargets.filter((row) => !row.hidden)
  }

  fields(row) {
    return [...row.querySelectorAll("input:not([type='hidden'])")]
  }

  focusField(row, column) {
    const fields = this.fields(row)
    const field = fields[column] || fields[0]
    field?.focus()
    field?.select?.()
  }

  changed() {
    this.element.dispatchEvent(new CustomEvent("line-items:changed", { bubbles: true }))
  }
}
