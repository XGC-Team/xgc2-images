#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "yaml"

apps = JSON.parse(ARGV[0])
repository = ENV.fetch("GITHUB_REPOSITORY").downcase
output_path = ENV.fetch("GITHUB_OUTPUT")

LAYERS = %w[base dev ros full].freeze
UBUNTUS = %w[bionic focal jammy noble].freeze

def native_arch_entry(arch)
  case arch
  when "amd64", "linux/amd64"
    { "arch" => "amd64", "platform" => "linux/amd64", "runner" => "ubuntu-latest" }
  when "arm64", "arm64/v8", "linux/arm64", "linux/arm64/v8"
    { "arch" => "arm64", "platform" => "linux/arm64", "runner" => "ubuntu-24.04-arm" }
  else
    raise "buildable app requests unsupported native architecture: #{arch}"
  end
end

def load_app(name)
  path = "apps/#{name}/app.yml"
  raise "missing #{path}" unless File.exist?(path)

  YAML.safe_load_file(path)
end

def ubuntu_of(app)
  parts = app.split("-")
  raise "cannot parse ubuntu from #{app}" unless parts.length >= 4 && parts[0, 2] == %w[xgc2 build]

  parts[2]
end

children = Hash.new { |h, k| h[k] = [] }
Dir.glob("apps/*/app.yml").each do |path|
  doc = YAML.safe_load_file(path)
  parent = doc["dependsOnApp"]
  next if parent.nil? || parent.empty?

  children[parent] << doc.fetch("key")
end

def descendants_of(app, children)
  out = []
  stack = children[app].dup
  while (current = stack.pop)
    next if out.include?(current)

    out << current
    stack.concat(children[current])
  end
  out
end

expanded = apps.dup
seen = expanded.to_h { |app| [app, true] }

expanded.dup.each do |app|
  next unless File.exist?("apps/#{app}/app.yml")

  doc = load_app(app)
  if doc["type"] == "build"
    descendants_of(app, children).each do |child|
      next if seen[child]

      expanded << child
      seen[child] = true
    end
    next
  end

  dependency = doc["dependsOnApp"]
  next if dependency.nil? || dependency.empty? || seen[dependency]
  next if doc["rebuildDependency"] == false

  expanded << dependency
  seen[dependency] = true
end

legacy_build = []
legacy_dependent_build = []
mirror = []
legacy_manifest = []
legacy_dependent_manifest = []
chain_by_ubuntu = Hash.new { |h, k| h[k] = [] }
chain_manifest = []
seen_manifest = {}

expanded.each do |app|
  doc = load_app(app)
  version = doc.fetch("version")
  image = "ghcr.io/#{repository}/#{app}"
  architectures = Array(doc["architectures"] || ["amd64"])
  buildable = File.exist?("apps/#{app}/Dockerfile")
  parent = doc["dependsOnApp"]
  parent_image = nil
  if parent && !parent.empty?
    parent_doc = load_app(parent)
    parent_image = "ghcr.io/#{repository}/#{parent}:#{parent_doc.fetch("version")}"
  end

  unless buildable
    mirror << {
      "app" => app,
      "version" => version,
      "image" => image,
      "source_image" => doc["upstreamImage"] || doc["image"],
      "architectures" => architectures
    }
    next
  end

  entries = architectures.map { |arch| native_arch_entry(arch) }
  multiarch = entries.length > 1
  layer = doc["type"] == "build" ? doc.fetch("buildLayer") : nil
  raise "build app #{app} has unknown buildLayer #{layer.inspect}" if doc["type"] == "build" && !LAYERS.include?(layer)

  if layer
    chain_by_ubuntu[ubuntu_of(app)] << {
      "layer" => layer,
      "order" => LAYERS.index(layer),
      "app" => app,
      "version" => version,
      "image" => image,
      "multiarch" => multiarch,
      "no_cache" => doc["noCache"] == true,
      "context" => ".",
      "file" => "apps/#{app}/Dockerfile",
      "from_image" => doc["fromImage"],
      "parent_image" => parent_image,
      "arches" => entries.map { |entry| entry["arch"] }
    }
    if multiarch && !seen_manifest[app]
      chain_manifest << {
        "app" => app,
        "version" => version,
        "image" => image,
        "arches" => entries.map { |entry| entry["arch"] }
      }
      seen_manifest[app] = true
    end
    next
  end

  target = parent ? legacy_dependent_build : legacy_build
  manifest_target = parent ? legacy_dependent_manifest : legacy_manifest
  entries.each do |entry|
    target << entry.merge(
      "app" => app,
      "version" => version,
      "image" => image,
      "multiarch" => multiarch,
      "no_cache" => doc["noCache"] == true,
      "version_only" => doc["publishVersionOnly"] == true,
      "context" => "apps/#{app}",
      "file" => "apps/#{app}/Dockerfile",
      "parent_image" => ""
    )
  end
  manifest_target << {
    "app" => app,
    "version" => version,
    "image" => image,
    "arches" => entries.map { |entry| entry["arch"] }
  } if multiarch
end

chain = []
chain_by_ubuntu.keys.sort.each do |ubuntu|
  steps = chain_by_ubuntu[ubuntu].sort_by { |item| item["order"] }
  %w[amd64 arm64].each do |arch|
    entry = native_arch_entry(arch)
    layers = steps.select { |item| item["arches"].include?(arch) }.map do |item|
      parent = if item["parent_image"]
                 "#{item["parent_image"]}-#{arch}"
               else
                 item["from_image"].to_s
               end
      {
        "app" => item["app"],
        "version" => item["version"],
        "image" => item["image"],
        "file" => item["file"],
        "context" => item["context"],
        "no_cache" => item["no_cache"],
        "multiarch" => item["multiarch"],
        "parent_image" => parent
      }
    end
    next if layers.empty?

    chain << entry.merge(
      "ubuntu" => ubuntu,
      "layers" => JSON.generate(layers)
    )
  end
end

chain_manifest.sort_by! do |row|
  [UBUNTUS.index(ubuntu_of(row["app"])) || 99, LAYERS.index(load_app(row["app"]).fetch("buildLayer")) || 99]
end

def matrix(rows)
  JSON.generate({ "include" => rows })
end

File.open(output_path, "a") do |out|
  out.puts "build_matrix=#{matrix(legacy_build)}"
  out.puts "dependent_build_matrix=#{matrix(legacy_dependent_build)}"
  out.puts "mirror_matrix=#{matrix(mirror)}"
  out.puts "manifest_matrix=#{matrix(legacy_manifest)}"
  out.puts "dependent_manifest_matrix=#{matrix(legacy_dependent_manifest)}"
  UBUNTUS.each do |ubuntu|
    rows = chain.select { |row| row["ubuntu"] == ubuntu }
    manifests = chain_manifest.select { |row| ubuntu_of(row["app"]) == ubuntu }
    out.puts "chain_#{ubuntu}=#{matrix(rows)}"
    out.puts "chain_manifest_#{ubuntu}=#{matrix(manifests)}"
  end
end

warn "legacy build=#{legacy_build.length} dependent=#{legacy_dependent_build.length} mirror=#{mirror.length}"
warn "chains=#{chain.length} chain_manifests=#{chain_manifest.length}"
chain.each do |row|
  warn "  #{row["ubuntu"]}-#{row["arch"]}: #{JSON.parse(row["layers"]).map { |s| s["app"] }.join(" -> ")}"
end
