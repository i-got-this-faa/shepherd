this prject is called fleet management system
all it does is provide organization a unified control layer to manage all of there deployed computers (win/mac/linux)

it is done by using nix under the hud on all three os 

nix for linux
darwin for macos
custom mapper for windows 

this will allow the organization to create one unified configuration for all their computers / hardware and have one central place to manage all of them
this will include the updates, profiles, and deployments

we also will provide a dashboard to monitor the fleet and track the progress of updates and deployments and add ai capabilities to dashboards 

lets dive into the details of the usecase 

the deployed mech would be read only root filesystem and only writable via the control layer
the control layer would be a separate process that manages the fleet

the linux is the most simple to do as we have nixos and the best
for mac os we have most of the work done already by the nix darwin project https://github.com/nix-darwin/nix-darwin
but for windows we have no good solution yet
we are thinking of making a custom mapper for windows that will map all the commands to the windows api and provide a unified control layer for windows under one nix file for all 3 os

for windows we want to map the follwoing 
1. win api 
2. registry
3. group policy
4. winget
5. wmi
6. windows update

what are your thoughts on this ???
