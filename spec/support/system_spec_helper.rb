# Waiting for the page to have drawn.
#
# Two frames, because the first is only scheduled by the call: the second
# callback cannot run until the first has been composited. That makes this a
# barrier for "the page has painted what it just laid out", which is what a
# caller wants after changing the viewport.
#
# It is not a remedy for lost input. Clicks go missing in this environment
# while frames are still arriving in milliseconds; see
# `spec/support/capybara_click_delivery.rb`.
module SystemFrameHelper
  def wait_for_animation_frame
    return unless page.driver.is_a?(Capybara::Selenium::Driver)

    page.evaluate_async_script(<<~JS)
      var done = arguments[0]
      requestAnimationFrame(function () { requestAnimationFrame(function () { done() }) })
    JS
  end
end

# Window sizing for the browser-backed specs.
#
# A resize is asynchronous in two directions: the browser has to apply the new
# bounds and the page has to lay out and paint at the new size. Interacting in
# between reads a viewport that is about to change and clicks coordinates that
# are about to move, so every resize waits for the size the caller asked for
# and then for a frame drawn at it.
module SystemWindowHelper
  def resize_window_to(width, height)
    return unless page.driver.is_a?(Capybara::Selenium::Driver)

    page.driver.browser.manage.window.resize_to(width, height)
    wait_for_window_size(width, height)
    wait_for_animation_frame
  end

  private

    def wait_for_window_size(width, height)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Capybara.default_max_wait_time

      loop do
        break if page.evaluate_script("[ window.outerWidth, window.outerHeight ]") == [ width, height ]
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.05
      end
    end
end

RSpec.configure do |config|
  config.include SystemFrameHelper, type: :system
  config.include SystemWindowHelper, type: :system

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
    resize_window_to(1400, 1400)
  end

  config.after(:each, type: :system) do
    Capybara.reset_sessions!
  end
end
