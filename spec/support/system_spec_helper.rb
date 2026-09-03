RSpec.configure do |config|
  # JavaScript system specs render the real stylesheet. Without a Tailwind build
  # the page is unstyled and visibility assertions (status dots, hidden
  # regions, overflow containers) pass or fail for the wrong reasons.
  # Tailwind only emits the utilities it finds in views and JavaScript, so any
  # template change can invalidate the build; a v4 build takes well under a
  # second, so rebuild unconditionally when JavaScript specs will run.
  config.before(:suite) do
    if RSpec.world.filtered_examples.values.flatten.any? { |ex| ex.metadata[:type] == :system && ex.metadata[:js] }
      system("bin/rails", "tailwindcss:build", exception: true)
    end
  end

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
