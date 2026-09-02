RSpec.configure do |config|
  config.before(:each, type: :system) do
    driven_by :rack_test
  end

  config.before(:each, type: :system, js: true) do
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]
    page.driver.browser.manage.window.resize_to(1400, 1400) if page.driver.respond_to?(:browser)
  end

  config.after(:each, type: :system) do
    Capybara.reset_sessions!
  end
end
