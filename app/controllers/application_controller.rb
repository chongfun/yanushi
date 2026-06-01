class ApplicationController < ActionController::Base
  include Authentication
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private
    def authenticated_user
      current_session = Current.session
      raise ActionController::RoutingError, "Authentication required" unless current_session

      current_session.user
    end
end
