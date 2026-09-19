@{
    SchemaVersion = 1
    MinimumProvenWslVersion = '2.7.13'
    SelectionStateRelativePath = 'dotfiles\windows-selection.json'
    Scoop = @{
        NocttyBucket = @{
            Name = 'noctty'
            Url = 'https://github.com/amanthanvi/scoop-noctty'
        }
        NocttyPackage = @{
            Name = 'noctty'
            QualifiedName = 'noctty/noctty'
            Executable = 'noctty.exe'
        }
        ExtrasBucket = @{
            Name = 'extras'
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
