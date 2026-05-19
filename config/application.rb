require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Yanushi
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Active Record Encryption key setup (using out-of-the-box keys for development/testing)
    config.active_record.encryption.primary_key = "Y0QmkDuj0fMrjh9Q6NFmMgTo1TSb0lzV"
    config.active_record.encryption.deterministic_key = "CtnBorkeD5Rxk3ES9oJyCjqdlwhMxgap"
    config.active_record.encryption.key_derivation_salt = "U1q34XHoHWMcG8lNAFwHzFf0MW6ycVgp"
  end
end
