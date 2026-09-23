@{
    SchemaVersion = 1
    MinimumProvenWslVersion = '2.7.13'
    SelectionStateRelativePath = 'dotfiles\windows-selection.json'
    Scoop = @{
        # Scoop's installer at one reviewed commit of ScoopInstaller/Install,
        # refused before it runs unless its SHA-256 is this one (#504). Bump
        # both together after reading the new commit's install.ps1;
        # ./scripts/check-pin-freshness.sh reports when upstream has moved.
        InstallerCommit = '1e2f334083d609986d8c8bc9e31ae8e87c39fab4'
        InstallerSha256 = '94f983b190438311e006b957db7c8422709e0ba62a6c2ac04e278164108f2512'
        NocttyBucket = @{
            Name = 'noctty'
            # The installer passes this to `scoop bucket add`, so it is a git
            # clone of a third-party repository and a trust root of its own.
            # network-source: scoop-noctty-bucket
            Url = 'https://github.com/amanthanvi/scoop-noctty'
        }
        NocttyPackage = @{
            Name = 'noctty'
            QualifiedName = 'noctty/noctty'
            Executable = 'noctty.exe'
        }
        ExtrasBucket = @{
            Name = 'extras'
            # network-source: scoop-extras-bucket
            Url = 'https://github.com/ScoopInstaller/Extras'
        }
        HandyPackage = @{
            Name = 'handy'
            QualifiedName = 'extras/handy'
            Executable = 'handy.exe'
        }
    }
    NocttyManagedFiles = @(
        @{
            Name = 'shared Ghostty configuration'
            Source = 'ghostty\.config\ghostty\shared.conf'
            Target = 'dotfiles\ghostty.conf'
        },
        @{
            Name = 'Noctty theme helper'
            Source = 'platforms\windows\set-noctty-theme.ps1'
            Target = 'dotfiles\set-theme.ps1'
        }
    )
}
