import { Controller } from "@hotwired/stimulus"

// A category picker that filters as you type (UiFormBuilder#category_select). The hidden native select is
// what the form submits, so only one of its options (a category, or none) can be sent, never free text.
//
// - Focus selects the text; typing part of a category or group name opens the list of matches (every word
//   must match, accents and case ignored), the first one highlighted.
// - Up / Down move; Enter takes the highlighted one (with no match it does nothing); Tab takes it too when
//   something was typed, then moves on; Escape closes and puts the chosen name back. Alt+Down opens the whole list.
// - Enter in a field with no category takes the suggestion (data-combobox-suggestion-value), which is also
//   listed first.
// - Leaving the field: empty text clears the category, anything else that was not chosen is undone.
// Choosing sets the select and fires its "change", which the form's other controllers listen to.
export default class extends Controller {
  static targets = ["input", "listbox", "select"]
  static values = { suggestion: String, suggestionLabel: String }

  connect() {
    this.matches = []
    this.active = -1
  }

  focus() {
    this.inputTarget.select()
  }

  filter() {
    this.open(this.search(this.inputTarget.value))
  }

  keydown(event) {
    switch (event.key) {
      case "ArrowDown":
        event.preventDefault()
        if (this.isOpen) this.move(1)
        else this.open(this.search(this.typed ? this.inputTarget.value : ""))
        break
      case "ArrowUp":
        if (!this.isOpen) return
        event.preventDefault()
        this.move(-1)
        break
      case "Enter":
        if (event.ctrlKey || event.metaKey) return
        if (this.isOpen) {
          // An open list takes Enter: the highlighted match, or nothing when none matches (never the form's submit
          // with the old category still chosen behind the typed text).
          event.preventDefault()
          if (this.matches[this.active]) this.choose(this.matches[this.active].value)
        } else if (!this.selectTarget.value && this.suggestionValue && !this.typed) {
          event.preventDefault()
          this.choose(this.suggestionValue)
        }
        break
      case "Escape":
        if (!this.isOpen) return
        event.preventDefault()
        this.close()
        this.sync()
        break
      case "Tab":
        if (this.isOpen && this.typed && this.matches[this.active]) this.choose(this.matches[this.active].value)
        else this.close()
        break
    }
  }

  blur() {
    this.close()
    if (this.inputTarget.value.trim() === "") this.choose("")
    else this.sync()
  }

  // The select changed (a choice here, or a suggestion taken elsewhere): show its name.
  sync() {
    const option = this.selectTarget.selectedOptions[0]
    const chosen = option && option.value !== ""
    this.inputTarget.value = chosen ? option.text : ""
    this.inputTarget.title = chosen ? `${option.parentElement.label} / ${option.text}` : ""
  }

  choose(value) {
    this.close()
    if (this.selectTarget.value !== value) {
      this.selectTarget.value = value
      this.selectTarget.dispatchEvent(new Event("change", { bubbles: true }))
    }
    this.sync()
  }

  // --- The list ------------------------------------------------------------------------------------------

  get options() {
    this.cachedOptions ||= [...this.selectTarget.querySelectorAll("option")]
      .filter((option) => option.value !== "")
      .map((option) => {
        const group = option.parentElement.label || ""
        return { value: option.value, label: option.text, group, search: normalize(`${option.text} ${group}`) }
      })
    return this.cachedOptions
  }

  // What was typed differs from the chosen name.
  get typed() {
    return this.inputTarget.value !== (this.selectTarget.selectedOptions[0]?.text ?? "") && this.inputTarget.value !== ""
  }

  search(query) {
    const words = normalize(query).split(/\s+/).filter(Boolean)
    const found = this.options.filter((option) => words.every((word) => option.search.includes(word)))
    const suggestion = found.findIndex((option) => option.value === this.suggestionValue)
    if (suggestion > 0) found.unshift(...found.splice(suggestion, 1))
    return found
  }

  get isOpen() {
    return !this.listboxTarget.hidden
  }

  open(matches) {
    this.matches = matches
    this.listboxTarget.replaceChildren(...matches.map((option, index) => this.optionElement(option, index)))
    if (matches.length === 0) {
      const empty = document.createElement("li")
      empty.className = "combobox-empty"
      empty.textContent = "No category matches"
      this.listboxTarget.append(empty)
    }
    this.listboxTarget.hidden = false
    this.inputTarget.setAttribute("aria-expanded", "true")
    this.highlight(matches.length ? 0 : -1)
  }

  close() {
    this.listboxTarget.hidden = true
    this.inputTarget.setAttribute("aria-expanded", "false")
    this.inputTarget.removeAttribute("aria-activedescendant")
    this.active = -1
  }

  move(step) {
    if (this.matches.length === 0) return
    this.highlight((this.active + step + this.matches.length) % this.matches.length)
  }

  highlight(index) {
    this.active = index
    this.listboxTarget.querySelectorAll("[role='option']").forEach((element, position) => {
      element.setAttribute("aria-selected", position === index ? "true" : "false")
      if (position === index) {
        this.inputTarget.setAttribute("aria-activedescendant", element.id)
        element.scrollIntoView({ block: "nearest" })
      }
    })
    if (index < 0) this.inputTarget.removeAttribute("aria-activedescendant")
  }

  optionElement(option, index) {
    const element = document.createElement("li")
    element.id = `${this.listboxTarget.id}_${option.value}`
    element.setAttribute("role", "option")
    element.className = "combobox-option"
    const name = document.createElement("span")
    name.textContent = option.label
    const group = document.createElement("span")
    group.className = "combobox-option-group"
    group.textContent = option.value === this.suggestionValue ? `${option.group} · suggested` : option.group
    element.append(name, group)
    // mousedown, not click: the field keeps its focus, so its blur does not undo the choice first.
    element.addEventListener("mousedown", (event) => {
      event.preventDefault()
      this.choose(option.value)
    })
    element.addEventListener("mousemove", () => this.highlight(index))
    return element
  }
}

function normalize(text) {
  return text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase()
}
