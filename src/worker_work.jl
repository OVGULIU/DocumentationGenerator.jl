using GitHub, Pkg
using Pkg: TOML

include("DocumentationGenerator.jl")

function create_docs(pspec::Pkg.Types.PackageSpec, buildpath)
    _module, rootdir = DocumentationGenerator.install_and_use(pspec)
    pkgname = pspec.name

    type, uri = DocumentationGenerator.parse_project(rootdir)
    @info "$(pkgname) specifies docs of type $(type)"

    if type === :dir
        @info("building `dir` docs")
        return build_local_dir_docs(pkgname, _module, rootdir, buildpath, uri)
    elseif type === :gitrepo
        @info("building `gitrepo` docs")
        return build_git_docs(pkgname, rootdir, buildpath, uri)
    elseif type === :hosted
        @info("building `hosted` docs")
        return build_hosted_docs(pkgname, rootdir, buildpath, uri)
    end
    @error("invalid doctype")
end

function build_local_dir_docs(pkgname, _module, rootdir, buildpath, uri)
    # package doesn't load, so let's only use the README
    if _module === nothing
        return mktempdir() do root
            DocumentationGenerator.readme_docs(pkgname, root, rootdir)
            cp(joinpath(root, "build"), buildpath, force = true)
            return :default, rootdir
        end
    end

    # actual Documenter docs
    try
        for docdir in (uri, joinpath.(rootdir, ("docs", "doc"))...)
            if isdir(docdir)
                makefile = joinpath(docdir, "make.jl")
                # create customized makefile with removed deploydocs + modified makedocs
                make_expr, builddir = DocumentationGenerator.rewrite_makefile(makefile)
                cd(docdir) do
                    eval(make_expr)
                end
                cp(builddir, buildpath, force=true)
                return :real, rootdir
            end
        end
    catch err
        @error("Tried building Documenter.jl docs but failed.", error=err)
    end
    @info("Building default docs.")

    # default docs
    mktempdir() do root
        DocumentationGenerator.default_docs(pkgname, root, rootdir)
        cp(joinpath(root, "build"), buildpath, force = true)
        return :default, rootdir
    end
end

function build_hosted_docs(pkgname, rootdir, buildpath, uri)
    # js redirect
    open(joinpath(buildpath, "index.html"), "w") do io
        println(io,
            """
            <!DOCTYPE html>
            <html>
                <head>
                    <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
                    <script type="text/javascript">
                        window.onload = function () {
                            window.location.replace("$(uri)");
                        }
                    </script>
                </head>
                <body>
                    Redirecting to <a href="$(uri)">$(uri)</a>.
                </body>
            </html>
            """
        )
    end
    # download search index
    try
        download(uri*"/search_index.js", joinpath(buildpath, "search_index.js"))
    catch err
        @error("search index download failed for $(uri)", exception = err)
    end
    return :real, rootdir
end

function build_git_docs(pkgname, rootdir, buildpath, uri)
    mktempdir() do dir
        cd(dir)
        run(`git clone --depth=1 $(uri) docsource`)
        docsproject = joinpath(dir, "docsource")
        cd(docsproject)
        build_local_dir_docs(pkgname, true, docsproject, buildpath, "")
    end

    return :real, rootdir
end

function license(repo, api = GitHub.DEFAULT_API; options...)
    results, page_data = GitHub.gh_get_paged_json(api, "/repos/$(GitHub.name(repo))/license"; options...)
    return results, page_data
end

function topics(repo, api = GitHub.DEFAULT_API; options...)
    results, page_data = GitHub.gh_get_paged_json(api, "/repos/$(GitHub.name(repo))/topics";
                                                  headers = Dict("Accept" => "application/vnd.github.mercy-preview+json"), options...)
    return results, page_data
end

function contributor_user(dict)
    Dict(
        "name" => dict["contributor"].login,
        "contributions" => dict["contributions"]
    )
end

function package_docs(name, url, version, buildpath)
    pspec = PackageSpec(name = name, version = version)
    @info("Generating docs for $name")
    meta = Dict()
    meta["name"] = name
    meta["url"] = url
    meta["version"] = version
    meta["installs"] = false

    doctype = :default
    try
        @info("building: $name")
        mktempdir() do envdir
            Pkg.activate(envdir)
            doctype, rootdir = create_docs(pspec, buildpath)
            meta["doctype"] = string(doctype)
            meta["installs"] = true
            @info("Done generating docs for $name")
            package_source(name, rootdir, buildpath)
        end
    catch e
        @error("Package $name didn't build", error = e)
        meta["installs"] = false
    end

    return meta
end

function package_metadata(name, url, version, buildpath)
    meta = Dict()
    authpath = joinpath(@__DIR__, "gh_auth.txt")
    if !isfile(authpath)
        @warn("No GitHub token found. Skipping metadata retrieval.")
        return meta
    end
    if !occursin("github.com", url)
        @warn("Can't retrieve metadata for $name (not hosted on github)")
        return meta
    end

    @info("Querying metadata for $name")
    try
        gh_auth = authenticate(readchomp(joinpath(@__DIR__, "gh_auth.txt")))
        matches = match(r".*/(.*)/(.*\.jl)(?:.git)?$", url)
        repo_owner = matches[1]
        repo_name = matches[2]
        repo_info = repo(repo_owner * "/" * repo_name, auth = gh_auth)
        meta["description"] = something(repo_info.description, "")
        meta["stargazers_count"]  = something(repo_info.stargazers_count, 0)
        license_dict, page = license(repo_info, auth = gh_auth)
        meta["license"] = something(license_dict["license"]["name"], "")
        meta["license_url"] = something(license_dict["license"]["url"], "")
        topics_dict, page = topics(repo_info, auth = gh_auth)
        meta["tags"] = something(topics_dict["names"], [])
        meta["owner"] = repo_owner
        meta["contributors"] = contributor_user.(contributors(repo_info, auth = gh_auth)[1])
    catch err
        @error(string("Couldn't get info for ", url), error = err)
    end
    @info("Done querying metadata for $name")

    return meta
end

function package_source(name, rootdir, buildpath)
    @info("Copying source code for $name")
    if isdir(rootdir)
        cp(rootdir, joinpath(buildpath, "_packagesource"); force=true)
    end
    @info("Done copying source code for $name")
end

function build(name, url, version, buildpath)
    meta = package_docs(name, url, version, buildpath)
    merge!(meta, package_metadata(name, url, version, buildpath))
    @info "making buildpath"
    isdir(buildpath) || mkpath(joinpath(buildpath))
    @info "opening meta.toml"
    open(joinpath(buildpath, "meta.toml"), "w") do io
        @info "writing meta.toml"
        TOML.print(io, meta)
    end
end

build(ARGS...)
