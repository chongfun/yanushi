// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import { Turbo } from "@hotwired/turbo-rails"
import "controllers"
import { showConfirmDialog } from "controllers/turbo_confirm_controller"

// Delegate Turbo confirmation to custom dialog
const confirmMethod = (message, _element) => {
  return showConfirmDialog(message)
}

if (Turbo.config?.forms) {
  Turbo.config.forms.confirm = confirmMethod
}
Turbo.setConfirmMethod(confirmMethod)
