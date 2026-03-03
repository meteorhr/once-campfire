class ApplicationController < ActionController::Base
  include AllowBrowser, Authentication, Authorization, BlockBannedRequests, SetCurrentRequest, SetLocale, SetPlatform, TrackedRoomVisit, VersionHeaders
  include Turbo::Streams::Broadcasts, Turbo::Streams::StreamName
end
