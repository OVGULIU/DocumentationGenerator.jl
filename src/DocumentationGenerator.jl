module DocumentationGenerator

using Pkg
using Pkg.TOML
using Pkg.Types
using Documenter

"""
    default_docs(package, root, pkgroot)

Generates a default documentation for a package without Documenter.jl docs.
"""
function default_docs(package, root, pkgroot)
    doc_source = joinpath(root, "src")
    mkpath(doc_source)
    pages = ["Docstrings" => "autodocs.md"]
    readme = joinpath(pkgroot, "README.md")
    if isfile(readme)
        newreadmepath = joinpath(doc_source, "index.md")
        cp(readme, newreadmepath)
        copylocallinks(readme, newreadmepath)
        push!(pages, "Readme" => "index.md")
    end
    pkg_sym = Symbol(package)
    @eval Module() begin
        using Pkg
        Pkg.add("Documenter")
        using Documenter
        using $pkg_sym
        open(joinpath($doc_source, "autodocs.md"), "w") do io
            println(io, """
            ```@autodocs
            Modules = [$($pkg_sym)]
            ```
            """)
        end
        makedocs(
            format = Documenter.HTML(),
            sitename = "$($package).jl",
            modules = [$pkg_sym],
            root = $root,
            pages = $(reverse(pages))
        )
    end
end

"""
    readme_docs(package, root, pkgroot)

Generates README based fallback docs when the package installs but can't be loaded.
"""
function readme_docs(package, root, pkgroot)
    doc_source = joinpath(root, "src")
    mkpath(doc_source)
    pages = []
    readme = joinpath(pkgroot, "README.md")
    if isfile(readme)
        newreadmepath = joinpath(doc_source, "index.md")
        cp(readme, newreadmepath)
        copylocallinks(readme, newreadmepath)
        push!(pages, "Readme" => "index.md")
    end
    pkg_sym = Symbol(package)
    @eval Module() begin
        using Pkg
        Pkg.add("Documenter")
        using Documenter
        makedocs(
            format = Documenter.HTML(),
            sitename = "$($package).jl",
            modules = [Module()],
            root = $root,
            pages = $(reverse(pages))
        )
    end
end

function parse_project(root)
    project_path = joinpath(root, "Project.toml")
    if isfile(project_path)
        toml = Pkg.TOML.parsefile(project_path)
        docs = get(get(toml, "metadata", Dict()), "documentation", Dict())
        if haskey(docs, "hosted")
            return :hosted, docs["hosted"]
        elseif haskey(docs, "gitrepo")
            return :gitrepo, docs["gitrepo"]
        elseif haskey(docs, "dir")
            return :dir, joinpath(root, docs["dir"])
        end
    end
    return :dir, joinpath(root, "docs")
end

using Markdown
"""
    copylocallinks(originalreadme, readmepath)

Copy relative link targets in the `originalreadme` such that they are reachable from `readmepath` as well.
"""
function copylocallinks(originalreadme, readmepath)
    basepath = normpath(joinpath(originalreadme, ".."))
    newbasepath = normpath(joinpath(readmepath, ".."))
    contents = String(read(readmepath))
    md = Markdown.parse(contents)
    links = []
    recurseMDcontents(md, links)
    for link in links
        (startswith(link, "http") || isabspath(link)) && continue
        ispath(dirname(joinpath(newbasepath, link))) || mkpath(dirname(joinpath(newbasepath, link)))
        cp(joinpath(basepath, link), joinpath(newbasepath, link))
    end
end
function recurseMDcontents(md, links)
    isdefined(md, :content) && foreach(c -> recurseMDcontents(c, links), md.content)
end
recurseMDcontents(md::Markdown.Link, links) = push!(links, md.url)
recurseMDcontents(md::Markdown.Image, links) = push!(links, md.url)

function parseall(str)
    pos = firstindex(str)
    exs = []
    while pos <= lastindex(str)
        ex, pos = Meta.parse(str, pos)
        push!(exs, ex)
    end
    if length(exs) == 0
        throw(ParseError("end of input"))
    elseif length(exs) == 1
        return exs[1]
    else
        return Expr(:block, exs...)
    end
end

"""
Rewrites the docs/make.jl for a given package to not deploy and respect
our build folders. This respects any custom scripts needed to build the docs
while disabling deploy + putting the right args into makedocs
"""
function rewrite_makefile(makefile)
    ast = parseall(read(makefile, String))
    make_expr = Expr(:block)
    push!(make_expr.args, :(using Pkg))
    buildpath = joinpath(dirname(makefile), "build")
    for elem in ast.args
        # skip deply(...) - we don't want to deploy
        Meta.isexpr(elem, :call) && elem.args[1] == :deploydocs && continue
        if Meta.isexpr(elem, :call) && elem.args[1] == :makedocs
            # rewrite makedoc call to respect our requirements
            new_args = []
            for argument in elem.args
                if Meta.isexpr(argument, :kw)
                    name, arg = argument.args
                    # assure that we generate HTML
                    if name == :format
                        argument.args[2] = :(Documenter.HTML())
                    end
                    # filter out root + build dir
                    if name == :build
                        # if there is a custom build folder, record it!
                        cd(dirname(makefile)) do
                            # uhm, joinpath(path1, path2) doesn't work...
                            # considering splitting this mayself, but this seems
                            # to be the easiest way to get the abspath respecting
                            # build path needs to be relative to root path
                            buildpath = abspath(arg)
                        end
                    end
                end
                push!(new_args, argument)
            end
            push!(new_args,
                Expr(:kw, :root, dirname(makefile)),
            )
            elem = Expr(:call, new_args...)
        end
        # Pkg.add packages required by package build script
        if Meta.isexpr(elem, :using)
            pkgs = Symbol[]
            for arg in elem.args
                if Meta.isexpr(arg, :.) && length(arg.args) == 1
                    push!(pkgs, arg.args[1])
                end
            end
            push!(make_expr.args, Expr(:call, :(Pkg.add), [string.(pkgs)...]))
        end

        push!(make_expr.args, elem)
    end
    return make_expr, buildpath
end

struct PkgNoWork <: Exception
    name::String
end

function install_and_use(pspec)
    # add dependencies as well? will be trivial with a package containing Project.toml
    try
        Pkg.add(pspec)
    catch e
        @error exception=e
        throw(PkgNoWork(pspec.name))
    end
    pkg_sym = Symbol(pspec.name)

    # needs to be main, because documenter wants to have the symbol in main -.-
    pkg_module = try
        @eval(Main, (using $pkg_sym; $pkg_sym))
    catch e
        nothing
    end
    pkg_module, normpath(joinpath(dirname(Base.find_package(pspec.name)), ".."))
end


"""
    run_with_timeout(
        command; log=stdout, timeout = 5*60, name = "",
        wait_time = 1, verbose = true
    )

Runs `command` and pipes all output to `log`. The process will be terminated after
`timeout` seconds without any output. `name` describes the process in log messages,
and `verbose` determines whether meta-logs ("process started" etc.) will be printed.
"""
function run_with_timeout(
        command; log=stdout, timeout = 5*60, name = "",
        wait_time = 1, verbose = true
    )

    out_io = IOBuffer()
    err_io = IOBuffer()
    pipe = pipeline(command, stdout = out_io, stderr = err_io)
    process = run(pipe, wait = false)
    timeout_start = time()

    task = @async begin
        logfallback = false
        io = try
            log isa String ? open(log, "w") : log
        catch err
            @error "Error opening logfile, falling back to stdout" error=err
            logfallback = true
            stdout
        end
        try
            tstart = time()
            verbose && @info("starting $name")
            while process_running(process)
                elapsed = (time() - timeout_start)
                if elapsed > timeout
                    verbose && @info("killing $name")
                    kill(process)
                    break
                end

                errstr, outstr = String.(take!.((err_io, out_io)))
                is_silent = length(errstr) == 0 && length(outstr) == 0
                isempty(outstr) || println(io, outstr)
                isempty(errstr) || println(io, errstr)

                # if something printed reset timeout
                if !is_silent
                    timeout_start = time()
                end

                sleep(wait_time)
            end

            verbose && @info("$name completed in $(round(time() - tstart, digits=1)) seconds")
        catch err
            @error "Error while running $(name) with timeout." error=err
        finally
            errstr, outstr = String.(take!.((err_io, out_io)))
            isempty(outstr) || println(io, outstr)
            isempty(errstr) || println(io, errstr)

            flush(io)
            if log isa String && !logfallback
                close(io)
            end
        end
    end
    return process, task
end

"""
    installable_on_version(version = VERSION; registry=joinpath(homedir(), ".julia/registries/General"))

Returns a vector of named tuples `(name, url, versions)` of packages in `registry`
compatible with Julia version `version`.
"""
function installable_on_version(version = VERSION; registry=joinpath(homedir(), ".julia/registries/General"))
    allpkgs = []
    for initial in filter!(isdir, joinpath.(registry, readdir(registry)))
        for pkg in filter!(isdir, joinpath.(registry, initial, readdir(initial)))
            "Compat.toml" in readdir(pkg) || continue
            pkgtoml = Pkg.TOML.parsefile(joinpath(pkg, "Package.toml"))
            versions = Pkg.TOML.parsefile(joinpath(pkg, "Versions.toml"))
            compat = Pkg.TOML.parsefile(joinpath(pkg, "Compat.toml"))
            for pkgver in keys(compat)
                try
                    if haskey(compat[pkgver], "julia")
                        if any(in.(version, Pkg.Types.VersionRange.(compat[pkgver]["julia"])))
                            push!(allpkgs,
                                (
                                    name = pkgtoml["name"],
                                    url = pkgtoml["repo"],
                                    versions = [
                                                VersionNumber(v) for v in keys(versions) if
                                                    VersionNumber(v) in VersionRange(pkgver)
                                               ]
                                )
                            )
                        end
                    end
                catch err
                    @error err
                end
            end
        end
    end
    allpkgs
end

"""
    build_documentation(name, url, version; basepath=joinpath(@__DIR__, ".."))

Asynchronously build documentation for package `name`@`version` at `url` and
save the HTML docs to `\$basepath/build` with logs in `\$basepath/logs`.

Note that this will overwrite previous builds/logs.
"""
function build_documentation(name, url, version;
                             basepath = joinpath(@__DIR__, ".."),
                             juliacmd = first(Base.julia_cmd()))
    envpath = normpath(joinpath(@__DIR__, ".."))
    workerfile = joinpath(@__DIR__, "worker_work.jl")
    buildpath = joinpath(basepath, "build")
    logpath = joinpath(basepath, "logs")

    isdir(buildpath) || mkpath(buildpath)
    isdir(logpath) || mkpath(logpath)

    builddir = joinpath(buildpath, name, string(version))
    isdir(builddir) || mkpath(builddir)
    logfile = joinpath(logpath, "$name $version.log")
    cmd = `$(juliacmd) --project=$(envpath) --color=no --compiled-modules=no --startup-file=no -O0 $workerfile $name $url $version $builddir`

    process, task = run_with_timeout(cmd, log=logfile, name = string("docs build for package ", name))
    return process
end

"""
    build_documentations(
        packages;
        processes::Int = 8, sleeptime = 0.5,
        juliacmd = first(Base.julia_cmd()),
        basepath = joinpath(@__DIR__, ".."),
        filter_versions = last
    )

Asynchronously build documentation `packages` (typically the output of `installable_on_version` and
a vector of named tuples `(name, url, versions)`) and save the docs to `\$basepath/build` with logs
in `\$basepath/logs`. `filter_versions` is applied to the vector of available package versions to
decide which to build, so setting it to e.g. `identity` will build docs for all versions.

Note that this will overwrite previous builds/logs.
"""
function build_documentations(
        packages;
        processes::Int = 8, sleeptime = 0.5,
        juliacmd = first(Base.julia_cmd()),
        basepath = joinpath(@__DIR__, ".."),
        filter_versions = last
    )
    process_queue = []
    for (name, url, versions) in packages
        #those somehow get stuck - might be random
        while length(process_queue) >= processes
            filter!(process_running, process_queue)
            sleep(sleeptime)
        end
        for version in vcat(filter_versions(sort(versions)))
            process = build_documentation(name, url, version, basepath = basepath, juliacmd = juliacmd)
            push!(process_queue, process)
        end
    end
    for proc in process_queue
        wait(proc)
    end
end

end
