import { Controller } from "@hotwired/stimulus"

// Light / dark / system theme switch.
//
// Persists the choice to localStorage["theme"] and toggles the `.dark` class
// on <html>. The inline boot script in layouts/_head.html.slim reads the same
// key before first paint, so there is no flash on full page loads.
//
//   div data-controller="theme" data-action="turbo:morph@document->theme#render"
//     button role="radio" data-theme-target="option" data-theme-value-param="light" data-action="theme#set"
//
// A Turbo page refresh morphs the server's markup (every option unchecked) over the buttons while
// this controller stays connected, so the toggle re-renders itself after each morph.
const STORAGE_KEY = "theme"
const THEMES = ["light", "dark", "system"]
const CHANGED_EVENT = "theme:changed"

export default class extends Controller {
  static targets = ["option"]
  static classes = ["active", "inactive"]

  connect() {
    this.mediaQuery = window.matchMedia("(prefers-color-scheme: dark)")
    this.onSystemChange = () => { if (this.theme === "system") this.apply("system") }
    this.onThemeChanged = () => this.render()
    this.mediaQuery.addEventListener("change", this.onSystemChange)
    // Other toggles on the same page stay in sync.
    window.addEventListener(CHANGED_EVENT, this.onThemeChanged)
    this.apply(this.theme)
    this.render()
  }

  disconnect() {
    this.mediaQuery.removeEventListener("change", this.onSystemChange)
    window.removeEventListener(CHANGED_EVENT, this.onThemeChanged)
  }

  set(event) {
    const theme = event.params.value
    if (!THEMES.includes(theme)) return
    localStorage.setItem(STORAGE_KEY, theme)
    this.apply(theme)
    window.dispatchEvent(new CustomEvent(CHANGED_EVENT))
  }

  get theme() {
    const stored = localStorage.getItem(STORAGE_KEY)
    return THEMES.includes(stored) ? stored : "system"
  }

  apply(theme) {
    const resolved = theme === "system" ? (this.mediaQuery.matches ? "dark" : "light") : theme
    document.documentElement.classList.toggle("dark", resolved === "dark")
  }

  render() {
    const current = this.theme
    this.optionTargets.forEach((option) => {
      const active = option.dataset.themeValueParam === current
      option.setAttribute("aria-checked", active ? "true" : "false")
      if (this.hasActiveClass) {
        this.activeClasses.forEach((name) => option.classList.toggle(name, active))
      }
      if (this.hasInactiveClass) {
        this.inactiveClasses.forEach((name) => option.classList.toggle(name, !active))
      }
    })
  }
}
