import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "template", "container" ]

  add(event) {
    event.preventDefault()
    const content = this.templateTarget.innerHTML.replace(/NEW_RECORD/g, new Date().getTime().toString())
    this.containerTarget.insertAdjacentHTML("beforeend", content)
  }

  remove(event) {
    event.preventDefault()
    const wrapper = event.target.closest(".nested-form-wrapper")
    
    if (wrapper.dataset.newRecord === "true") {
      wrapper.remove()
    } else {
      const destroyInput = wrapper.querySelector("input[name*='_destroy']")
      if (destroyInput) destroyInput.value = "1"
      wrapper.style.display = "none"
    }
  }
}
