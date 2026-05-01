// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import { Turbo } from "@hotwired/turbo-rails"
import "controllers"

Turbo.setConfirmMethod((message, element) => {
  const dialog = document.getElementById("confirm-modal")
  if (!dialog) return window.confirm(message)

  const controller = window.Stimulus.getControllerForElementAndIdentifier(dialog, "turbo-confirm")
  if (!controller) return window.confirm(message)

  return controller.show(message)
})
