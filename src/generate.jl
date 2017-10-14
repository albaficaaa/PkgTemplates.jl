"""
    generate(
        pkg_name::AbstractString,
        t::Template;
        force::Bool=false,
        ssh::Bool=false,
    ) -> Void

Generate a package named `pkg_name` from `template`.

# Keyword Arguments
* `force::Bool=false`: Whether or not to overwrite old packages with the same name.
* `ssh::Bool=false`: Whether or not to use SSH for the remote.
* `backup_dir::AbstractString=""`: Directory in which to store the generated package if
  `t.dir` is not a valid directory. If left unset, a temporary directory will be created.

# Notes
The package is generated entirely in a temporary directory and only moved into
`joinpath(t.dir, pkg_name)` at the very end. In the case of an error, the temporary
directory will contain leftovers, but the destination directory will remain untouched
(this is especially helpful when `force=true`).
"""
function generate(
    pkg_name::AbstractString,
    t::Template;
    force::Bool=false,
    ssh::Bool=false,
    backup_dir::AbstractString="",
)
    mktempdir() do temp_dir
        generate(pkg_name, t, temp_dir; force=force, ssh=ssh, backup_dir=backup_dir)
    end
end

function generate(
    pkg_name::AbstractString,
    t::Template,
    dir::AbstractString;
    force::Bool=false,
    ssh::Bool=false,
    backup_dir::AbstractString="",
)
    pkg_name = Pkg.splitjl(pkg_name)
    pkg_dir = joinpath(t.dir, pkg_name)
    temp_pkg_dir = joinpath(dir, pkg_name)

    if !force && ispath(pkg_dir)
        throw(ArgumentError(
            "Path '$pkg_dir' already exists, use force=true to overwrite it."
        ))
    end

    # Initialize the repo and configure it.
    repo = LibGit2.init(temp_pkg_dir)
    info("Initialized git repo at $temp_pkg_dir")
    !isempty(t.gitconfig) && info("Applying git configuration")
    LibGit2.with(LibGit2.GitConfig, repo) do cfg
        for (key, val) in t.gitconfig
            LibGit2.set!(cfg, key, val)
        end
    end
    LibGit2.commit(repo, "Empty initial commit")
    info("Made initial empty commit")
    rmt = if ssh
        "git@$(t.host):$(t.user)/$pkg_name.jl.git"
    else
        "https://$(t.host)/$(t.user)/$pkg_name.jl"
    end
    # We need to set the remote in a strange way, see #8.
    close(LibGit2.GitRemote(repo, "origin", rmt))
    info("Set remote origin to $rmt")

    # Create the gh-pages branch if necessary.
    if haskey(t.plugins, GitHubPages)
        LibGit2.branch!(repo, "gh-pages")
        LibGit2.commit(repo, "Empty initial commit")
        info("Created empty gh-pages branch")
        LibGit2.branch!(repo, "master")
    end

    # Generate the files.
    files = vcat(
        gen_entrypoint(dir, pkg_name, t),
        gen_tests(dir, pkg_name, t),
        gen_require(dir, pkg_name, t),
        gen_readme(dir, pkg_name, t),
        gen_gitignore(dir, pkg_name, t),
        gen_license(dir, pkg_name, t),
        vcat([gen_plugin(plugin, t, dir, pkg_name) for plugin in values(t.plugins)]...),
    )

    LibGit2.add!(repo, files...)
    info("Staged $(length(files)) files/directories: $(join(files, ", "))")
    LibGit2.commit(repo, "Files generated by PkgTemplates")
    info("Committed files generated by PkgTemplates")
    multiple_branches = length(collect(LibGit2.GitBranchIter(repo))) > 1
    info("Moving temporary package directory into $(t.dir)/")
    try
        mkpath(dirname(pkg_dir))
        mv(temp_pkg_dir, pkg_dir; remove_destination=force)
    catch  # Likely cause is that t.dir can't be created (is a file, etc.).
        # We're just going to trust that backup_dir is a valid directory.
        backup_dir = if isempty(backup_dir)
            mktempdir()
        else
            abspath(backup_dir)
        end
        mkpath(backup_dir)
        mv(temp_pkg_dir, joinpath(backup_dir, pkg_name))
        warn("$pkg_name couldn't be moved into $pkg_dir, left package in $backup_dir")
    end

    info("Finished")
    if multiple_branches
        warn("Remember to push all created branches to your remote: git push --all")
    end
end

function generate(
    t::Template,
    pkg_name::AbstractString;
    force::Bool=false,
    ssh::Bool=false,
    backup_dir::AbstractString="",
)
    generate(pkg_name, t; force=force, ssh=ssh, backup_dir=backup_dir)
end

"""
    generate_interactive(
        pkg_name::AbstractString;
        force::Bool=false,
        ssh::Bool=false,
        backup_dir::AbstractString="",
        fast::Bool=false,
    ) -> Void

Interactively create a template, and then generate a package with it. Arguments and
keywords are used in the same way as in [`generate`](@ref) and
[`interactive_template`](@ref).
"""
function generate_interactive(
    pkg_name::AbstractString;
    force::Bool=false,
    ssh::Bool=false,
    backup_dir::AbstractString="",
    fast::Bool=false,
)
    generate(
        pkg_name,
        interactive_template(; fast=fast);
        force=force,
        ssh=ssh,
        backup_dir=backup_dir,
    )
end

"""
    gen_entrypoint(
        dir::AbstractString,
        pkg_name::AbstractString,
        template::Template,
    ) -> Vector{String}

Create the module entrypoint in the temp package directory.

# Arguments
* `dir::AbstractString`: The directory in which the files will be generated. Note that
  this will be joined to `pkg_name`.
* `pkg_name::AbstractString`: Name of the package.
* `template::Template`: The template whose entrypoint we are generating.

Returns an array of generated file/directory names.
"""
function gen_entrypoint(dir::AbstractString, pkg_name::AbstractString, template::Template)
    text = template.precompile ? "__precompile__()\n" : ""
    text *= """
        module $pkg_name

        # Package code goes here.

        end
        """

    gen_file(joinpath(dir, pkg_name, "src", "$pkg_name.jl"), text)
    return ["src/"]
end

"""
    gen_tests(
        dir::AbstractString,
        pkg_name::AbstractString,
        template::Template,
    ) -> Vector{String}

Create the test directory and entrypoint in the temp package directory.

# Arguments
* `dir::AbstractString`: The directory in which the files will be generated. Note that
  this will be joined to `pkg_name`.
* `pkg_name::AbstractString`: Name of the package.
* `template::Template`: The template whose tests we are generating.

Returns an array of generated file/directory names.
"""
function gen_tests(dir::AbstractString, pkg_name::AbstractString, template::Template)
    text = """
        using $pkg_name
        using Base.Test

        # Write your own tests here.
        @test 1 == 2
        """

    gen_file(joinpath(dir, pkg_name, "test", "runtests.jl"), text)
    return ["test/"]
end

"""
    gen_require(
        dir::AbstractString,
        pkg_name::AbstractString,
        template::Template,
    ) -> Vector{String}

Create the `REQUIRE` file in the temp package directory.

# Arguments
* `dir::AbstractString`: The directory in which the files will be generated. Note that
  this will be joined to `pkg_name`.
* `pkg_name::AbstractString`: Name of the package.
* `template::Template`: The template whose REQUIRE we are generating.

Returns an array of generated file/directory names.
"""
function gen_require(dir::AbstractString, pkg_name::AbstractString, template::Template)
    text = "julia $(version_floor(template.julia_version))\n"
    text *= join(template.requirements, "\n")

    gen_file(joinpath(dir, pkg_name, "REQUIRE"), text)
    return ["REQUIRE"]
end

"""
    gen_readme(
        dir::AbstractString,
        pkg_name::AbstractString,
        template::Template,
    ) -> Vector{String}

Create a README in the temp package directory with badges for each enabled plugin.

# Arguments
* `dir::AbstractString`: The directory in which the files will be generated. Note that
  this will be joined to `pkg_name`.
* `pkg_name::AbstractString`: Name of the package.
* `template::Template`: The template whose README we are generating.

Returns an array of generated file/directory names.
"""
function gen_readme(dir::AbstractString, pkg_name::AbstractString, template::Template)
    text = "# $pkg_name\n"
    done = []
    # Generate the ordered badges first, then add any remaining ones to the right.
    for plugin_type in BADGE_ORDER
        if haskey(template.plugins, plugin_type)
            text *= "\n"
            text *= join(
                badges(template.plugins[plugin_type], template.user, pkg_name),
                "\n",
            )
            push!(done, plugin_type)
        end
    end
    for plugin_type in setdiff(keys(template.plugins), done)
        text *= "\n"
        text *= join(
            badges(template.plugins[plugin_type], template.user, pkg_name),
            "\n",
        )
    end

    gen_file(joinpath(dir, pkg_name, "README.md"), text)
    return ["README.md"]
end

"""
    gen_gitignore(
        dir::AbstractString,
        pkg_name::AbstractString,
        template::Template,
    ) -> Vector{String}

Create a `.gitignore` in the temp package directory.

# Arguments
* `dir::AbstractString`: The directory in which the files will be generated. Note that
  this will be joined to `pkg_name`.
* `pkg_name::AbstractString`: Name of the package.
* `template::Template`: The template whose .gitignore we are generating.

Returns an array of generated file/directory names.
"""
function gen_gitignore(dir::AbstractString, pkg_name::AbstractString, template::Template)
    seen = [".DS_Store"]
    patterns = vcat([plugin.gitignore for plugin in values(template.plugins)]...)
    for pattern in patterns
        if !in(pattern, seen)
            push!(seen, pattern)
        end
    end
    text = join(seen, "\n")

    gen_file(joinpath(dir, pkg_name, ".gitignore"), text)
    return [".gitignore"]
end

"""
    gen_license(
        dir::AbstractString,
        pkg_name::AbstractString,
        template::Template,
    ) -> Vector{String}

Create a license in the temp package directory.

# Arguments
* `dir::AbstractString`: The directory in which the files will be generated. Note that
  this will be joined to `pkg_name`.
* `pkg_name::AbstractString`: Name of the package.
* `template::Template`: The template whose LICENSE we are generating.

Returns an array of generated file/directory names.
"""
function gen_license(dir::AbstractString, pkg_name::AbstractString, template::Template)
    if isempty(template.license)
        return String[]
    end

    text = "Copyright (c) $(template.years) $(template.authors)\n"
    text *= read_license(template.license)

    gen_file(joinpath(dir, pkg_name, "LICENSE"), text)
    return ["LICENSE"]
end

"""
    gen_file(file_path::AbstractString, text::AbstractString) -> Int

Create a new file containing some given text. Always ends the file with a newline.

# Arguments
* `file::AbstractString`: Path to the file to be created.
* `text::AbstractString`: Text to write to the file.

Returns the number of bytes written to the file.
"""
function gen_file(file::AbstractString, text::AbstractString)
    mkpath(dirname(file))
    if !endswith(text , "\n")
        text *= "\n"
    end
    open(file, "w") do fp
        return write(fp, text)
    end
end

"""
    version_floor(v::VersionNumber=VERSION) -> String

Format the given Julia version.

# Keyword arguments
* `v::VersionNumber=VERSION`: Version to floor.

Returns "major.minor" for the most recent release version relative to v. For prereleases
with v.minor == v.patch == 0, returns "major.minor-".
"""
function version_floor(v::VersionNumber=VERSION)
    if isempty(v.prerelease) || v.patch > 0
        return "$(v.major).$(v.minor)"
    else
        return "$(v.major).$(v.minor)-"
    end
end

"""
    substitute(template::AbstractString, view::Dict{String, Any}) -> String

Replace placeholders in `template` with values in `view` via
[`Mustache`](https://github.com/jverzani/Mustache.jl). `template` is not modified.

For information on how to structure `template`, see "Defining Template Files" section in
[Custom Plugins](@ref).

**Note**: Conditionals in `template` without a corresponding key in `view` won't error,
but will simply be evaluated as false.
"""
substitute(template::AbstractString, view::Dict{String, Any}) = render(template, view)

"""
    substitute(
        template::AbstractString,
        pkg_template::Template;
        view::Dict{String, Any}=Dict{String, Any}(),
    ) -> String

Replace placeholders in `template`, using some default replacements based on the
`pkg_template` and additional ones in `view`. `template` is not modified.
"""
function substitute(
    template::AbstractString,
    pkg_template::Template;
    view::Dict{String, Any}=Dict{String, Any}(),
)
    # Don't use version_floor here because we don't want the trailing '-' on prereleases.
    v = pkg_template.julia_version
    d = Dict{String, Any}(
        "USER" => pkg_template.user,
        "VERSION" => "$(v.major).$(v.minor)",
        "DOCUMENTER" => any(isa(p, Documenter) for p in values(pkg_template.plugins)),
        "CODECOV" => haskey(pkg_template.plugins, CodeCov),
        "COVERALLS" => haskey(pkg_template.plugins, Coveralls),
    )
    # d["AFTER"] is true whenever something needs to occur in a CI "after_script".
    d["AFTER"] = d["DOCUMENTER"] || d["CODECOV"] || d["COVERALLS"]
    return substitute(template, merge(d, view))
end
