class ApplicationController < ActionController::Base
  include Authentication
  allow_browser versions: :modern
  stale_when_importmap_changes

  private
    def authenticated_user
      current_session = Current.session
      raise ActionController::RoutingError, "Authentication required" unless current_session

      current_session.user
    end
end
