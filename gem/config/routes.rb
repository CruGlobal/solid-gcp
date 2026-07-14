# frozen_string_literal: true

SolidGcp::Engine.routes.draw do
  post "/perform"        => "tasks#perform"
  post "/launch"         => "tasks#launch"
  post "/sweep"          => "tasks#sweep"
  post "/recurring/:key" => "tasks#recurring"
end
