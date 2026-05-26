class ApplicationController < ActionController::Base
  include Authentication
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  around_action :switch_shard

  private

  def switch_shard(&block)
    user = resume_session&.user
    shard = user&.shard || "default" # fallback to default shard

    ShardedRecord.connected_to(role: :writing, shard: shard.to_sym, &block)
  end
end
