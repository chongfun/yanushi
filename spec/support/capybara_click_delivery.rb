# Verifying that the browser actually delivered a click.
#
# This headless Chrome intermittently swallows the input Capybara synthesizes.
# JavaScript keeps running, frames keep arriving within milliseconds, and the
# target sits unobstructed at valid coordinates with hit testing resolving to
# it, yet no click event reaches the document and nothing responds: not from
# Capybara's click, not from Selenium's Actions API, not from a DevTools mouse
# dispatch at any coordinate, and a keystroke sent at the same moment is
# dropped too. Nothing raises, so the spec reads it as an app that ignored the
# click. It strikes an arbitrary click once any other example has run first,
# and a click dispatched from the page drives the app correctly at the very
# moment a native one is being swallowed, so the application is not what is
# stuck.
#
# So every click is checked: a capture-phase listener on the document counts
# what arrives, and a click that produced nothing at all is dispatched again
# from the page. A real click always produces a click event, so this only fires
# where the alternative is a spurious failure. It also says so on stderr,
# because a click that silently does nothing can be a genuine regression, and
# that deserves to be visible rather than papered over.
#
# The native click still goes first, so everything it enforces still holds: the
# element has to be visible, in the viewport, enabled, and not covered by
# something else, or Selenium raises and the example fails as it should.
module CapybaraClickDelivery
  # Long enough for a click to make the round trip on a loaded machine, short
  # enough to pay repeatedly (a disabled control produces no click event by
  # design, and waits this out on every attempt).
  DELIVERY_WAIT = 1.0

  def click(*keys, **options)
    return super unless verifiable_click?(keys, options)

    delivered = click_count
    super
    return if click_reached_page?(delivered)

    warn "[click-delivery] the browser did not deliver a click on " \
         "<#{tag_name}> #{text.to_s.strip.slice(0, 40).inspect}; dispatching it from the page"
    session.execute_script("arguments[0].click()", self)
  end

  private

    # Modifier keys and coordinate offsets have no page-dispatched equivalent,
    # and only the browser-backed driver has a page to dispatch from: rack_test
    # clicks the app directly and has nothing to swallow them.
    def verifiable_click?(keys, options)
      keys.empty? &&
        (options.keys - [ :wait ]).empty? &&
        driver.is_a?(Capybara::Selenium::Driver)
    end

    def click_count
      session.execute_script(<<~'JS')
        if (!window.__capybaraClickProbe) {
          window.__capybaraClickProbe = true
          window.__capybaraClicks = 0
          document.addEventListener("click", function () { window.__capybaraClicks += 1 }, true)
        }
      JS
      session.evaluate_script("window.__capybaraClicks") || 0
    rescue StandardError
      # Whatever state the page is in, it is not one this can reason about.
      nil
    end

    def click_reached_page?(delivered)
      return true if delivered.nil?

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DELIVERY_WAIT

      loop do
        count = current_click_count
        # A counter that is gone means the document was replaced, and a dialog
        # or a navigation in flight means the click plainly did something.
        return true if count.nil? || count > delivered
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.05
      end
    end

    def current_click_count
      session.evaluate_script("window.__capybaraClicks")
    rescue StandardError
      nil
    end
end

Capybara::Node::Element.prepend(CapybaraClickDelivery)
