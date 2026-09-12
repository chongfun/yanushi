import { Controller } from "@hotwired/stimulus"

// A horizontally scrolling table is unreachable from the keyboard. Chrome does
// not make a scroll container focusable on its own, so someone without a mouse
// cannot reach the columns past the right edge (WCAG 2.1.1). The fix is a tab
// stop on the container, announced as a named region so its purpose is clear
// when focus lands there.
//
// The markup ships focusable and named, so the affordance survives with no
// JavaScript. This controller's job is the other half: a tab stop and a
// landmark on a table that already fits are noise, so it takes them off while
// the table is not scrolling and puts them back when a resize or a Turbo
// update makes it scroll again.
export default class extends Controller {
  connect() {
    // Read the name the server rendered before any of it is taken away.
    this.named = {
      role: this.element.getAttribute("role"),
      "aria-label": this.element.getAttribute("aria-label"),
      "aria-labelledby": this.element.getAttribute("aria-labelledby")
    }

    this.sync = this.sync.bind(this)
    this.observer = new ResizeObserver(this.sync)
    this.observer.observe(this.element)
    // The table as well as the container: a column grows and starts the
    // overflow while the container's own box stays the same size.
    if (this.element.firstElementChild) {
      this.observer.observe(this.element.firstElementChild)
    }
    this.sync()
  }

  disconnect() {
    this.observer.disconnect()
  }

  sync() {
    const wanted = this.element.scrollWidth - this.element.clientWidth > 1
    if (wanted === this.focusable) return

    // Taking the tab stop out from under the element the reader is standing on
    // would drop focus to the body, so a focused container keeps it until
    // focus moves elsewhere.
    if (!wanted && this.element.contains(document.activeElement)) return

    if (wanted) {
      this.element.setAttribute("tabindex", "0")
      for (const [name, value] of Object.entries(this.named)) {
        if (value) this.element.setAttribute(name, value)
      }
    } else {
      this.element.removeAttribute("tabindex")
      for (const name of Object.keys(this.named)) this.element.removeAttribute(name)
    }
  }

  get focusable() {
    return this.element.getAttribute("tabindex") !== null
  }
}
