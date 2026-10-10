# Untitled Sandbox Game

A voxel based, sandbox adventure game, heavily inspired by Ylands (created by Bohemia Interactive). Game takes place in a star system where small, stylized planets orbit a star. An entire system is one cohesive scene and the player can travel between planets seamlessly, with no loading screen.

## Core Concepts/Mechanics

- **Systems** are the primary game space, consisting of a number of planets. All of it is contained within one scene, allowing the player to travel seamlessly between worlds without a loading screen
- **Planets** are stylistically sized and can be easily circumnavigated. Planets will orbit their star and have a rotation.
- **Seasons** will occur on habitable, temperate planets. These planets will rotate on a tilted axis. This combined with their orbit around the star will inform biome generation and naturally create seasons.
- **Gardening** will be a critical mechanic. Ingredients can be gathered from various planets/animals and cultivated. Ingredients from one planet will help with survival in that environment
- **Survival** will include metrics such as oxygen, temperature, and hunger that will need to be managed
- **Inter-planet Travel** will involve building a space ship in a similar way that sea-faring ships are constructed in the game Ylands.
- **Teleporters** will provide the player with quick and instantaneous travel between multiple areas of the map and beyond. The goal is to make it so that, just like space flight, teleporters provide instant and seamless travel between two locations, similar to Farcasters in Dan Simmons' Hyperion Cantos series. Teleporters will come in two sizes: player sized and ship sized
- **Inter-system travel** is possible through the use of teleporter probes. When a player wants to travel beyond their current system, they must launch a teleporter probe into space. After a certain amount of time, this will create a teleporter end-point in a newly generated system and the player will now have a ship-size teleporter in their current system and the new system, allowing them to seamlessly fly from one system to another. When launching a probe, the player will be given settings to guide the probe that allow them to configure the parameters of the newly generated system.
- **Multiplayer** will be developed in-step with all other mechanics/systems. The idea is to implement a server-client architecture so that players can host dedicated servers if they would like to. A server will only consist a single star system. Teleporters to other systems may or may not be allowed in a multiplayer setting. I'll cross that bridge when I get there.
- **Mods** would be awesome to support. However, I have no idea how that works and it's not something I plan to look into.

## Licensing and Pricing

This game will be free to play with no monetization strategies other than a Ko-Fi Link. It will be published under some sort of open-source software license, but is still to be determined exactly which licensed is used.

## Development

As I am the only person on this project right now, I will be keeping track of development via GitHub issues. Want to help out? Get in touch with me by opening up a GitHub issue!

## AI Disclaimer

This repository is an experiment in AI-driven development, and it is different from the original project it was copied from.

The code up to the initial commit (`99e0e55`) was written entirely by a human. The original project used Claude strictly as a learning tool (explaining concepts, pointing out optimization opportunities, teaching), and its history was intentionally dropped when this copy was made.

Everything after that commit is written by Claude (Anthropic's AI), working with the repository owner, who sets direction and reviews the results. Commits made by Claude are marked with a `Co-Authored-By: Claude` trailer. Art and music in the repo (`assets/`, `blender/`) are human-made originals; any new assets are noted as such when added.

Because of this, the original project's rule against AI code does not apply here, and this repo is not accepting outside contributions that assume it does.