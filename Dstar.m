%Dstar D* navigation class
%
% A concrete subclass of the abstract Navigation class that implements the D*
% navigation algorithm.  This provides minimum distance paths and
% facilitates incremental replanning.
%
% Methods::
% plan              Compute the cost map given a goal and map
% path              Compute a path to the goal (inherited from Navigation)
% visualize         Display the obstacle map (deprecated)
% plot              Display the obstacle map
% costmap_modify    Modify the costmap
% modify_cost       Modify the costmap (deprecated, use costmap_modify)
% costmap_get       Return the current costmap
% costmap_set       Set the current costmap
% distancemap_get   Set the current distance map
% display           Print the parameters in human readable form
% char              Convert to string
%
% Properties::
% costmap    Distance from each point to the goal.
%
% Example::
%        load map1           % load map
%        goal = [50,30];
%        start=[20,10];
%        ds = Dstar(map);    % create navigation object
%        ds.plan(goal)       % create plan for specified goal
%        ds.path(start)      % animate path from this start location
%
% Notes::
% - Obstacles are represented by Inf in the costmap.
% - The value of each element in the costmap is the shortest distance from the 
%   corresponding point in the map to the current goal.
%
% References::
% - The D* algorithm for real-time planning of optimal traverses,
%   A. Stentz,
%   Tech. Rep. CMU-RI-TR-94-37, The Robotics Institute, Carnegie-Mellon University, 1994.
%   https://www.ri.cmu.edu/pub_files/pub3/stentz_anthony__tony__1994_2/stentz_anthony__tony__1994_2.pdf
% - Robotics, Vision & Control, Sec 5.2.2,
%   Peter Corke, Springer, 2011.
%
% See also Navigation, DXform, PRM.


% Copyright (C) 1993-2014, by Peter I. Corke
%
% This file is part of The Robotics Toolbox for MATLAB (RTB).
% 
% RTB is free software: you can redistribute it and/or modify
% it under the terms of the GNU Lesser General Public License as published by
% the Free Software Foundation, either version 3 of the License, or
% (at your option) any later version.
% 
% RTB is distributed in the hope that it will be useful,
% but WITHOUT ANY WARRANTY; without even the implied warranty of
% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
% GNU Lesser General Public License for more details.
% 
% You should have received a copy of the GNU Leser General Public License
% along with RTB.  If not, see <http://www.gnu.org/licenses/>.
%
% http://www.petercorke.com



% Implementation notes:
%
% All the state is kept in the structure called d
% X is an index into the array of states.
% state pointers are kept as matlab array index rather than row,col format

%TODO use pgraph class

% pic 7/09

classdef Dstar < Navigation

    properties (SetAccess=private, GetAccess=private)

        G         % index of goal point

        % info kept per cell (state)
        b       % backpointer (0 means not set)
        t       % tag: NEW OPEN CLOSED
        h       % distance map, path cost

        % list of open states: 2xN matrix
        %   each open point is a column, row 1 = index of cell, row 2 = k
        openlist



        changed

        openlist_maxlen     % keep track of maximum length
        
        
        % tag state values
        NEW = 0;
        OPEN = 1;
        CLOSED = 2;
    end
    
    properties (SetAccess=private, GetAccess=public)
        niter
        costmap   % world cost map: obstacle = Inf
        
    end
    
    methods

        % constructor
        function ds = Dstar(world, varargin)
            %Dstar.Dstar D* constructor
            %
            % DS = Dstar(MAP, OPTIONS) is a D* navigation object, and MAP is an
            % occupancy grid, a representation of a planar world as a
            % matrix whose elements are 0 (free space) or 1 (occupied).
            % The occupancy grid is coverted to a costmap with a unit cost
            % for traversing a cell.
            %
            % Options::
            % 'goal',G      Specify the goal point (2x1)
            % 'metric',M    Specify the distance metric as 'euclidean' (default)
            %               or 'cityblock'.
            % 'inflate',K   Inflate all obstacles by K cells.
            % 'progress'       Don't display the progress spinner
            %
            % Other options are supported by the Navigation superclass.
            %
            % See also Navigation.Navigation.

            % invoke the superclass constructor
            ds = ds@Navigation(world, varargin{:});



            



            % init the D* state variables
            ds.reset();
            if ~isempty(ds.goal)
                ds.goal_change();
            end
            ds.changed = false;
        end

        function reset(ds)
            %Dstar.reset Reset the planner
            %
            % DS.reset() resets the D* planner.  The next instantiation
            % of DS.plan() will perform a global replan.

            % build the matrices required to hold the state of each cell for D*
            ds.b = zeros(size(ds.costmap), 'uint32');  % backpointers
            ds.t = zeros(size(ds.costmap), 'uint8');   % tags
            ds.h = Inf*ones(size(ds.costmap));         % path cost estimate
            ds.openlist = zeros(2,0);                  % the open list, one column per point

            ds.openlist_maxlen = -Inf;
            
                        ds.occgrid2costmap(ds.occgridnav);
        end


        function s = char(ds)
            %Dstar.char Convert navigation object to string
            %
            % DS.char() is a string representing the state of the Dstar
            % object in human-readable form.
            %
            % See also Dstar.display, Navigation.char.
 
            % most of the work is done by the superclass
            s = char@Navigation(ds);

            % Dstar specific stuff
            if ~isempty(ds.costmap)
                s = char(s, sprintf('  costmap: %dx%d, open list %d', size(ds.costmap), numcols(ds.openlist)));
            else
                s = char(s, sprintf('  costmap: empty:'));
            end
        end

        function plot(ds, varargin)
            %Dstar.plot Visualize navigation environment
            %
            % DS.plot() displays the occupancy grid and the goal distance
            % in a new figure.  The goal distance is shown by intensity which
            % increases with distance from the goal.  Obstacles are overlaid
            % and shown in red.
            %
            % DS.plot(P) as above but also overlays a path given by the set
            % of points P (Mx2).
            %
            % See also Navigation.plot.
            
            plot@Navigation(ds, varargin{:}, 'distance', ds.h);
        end


        function pp = query(nav, start, varargin)
            
            opt.animate = false;
            
            opt = tb_optparse(opt, varargin);
            
            % make sure start and goal are set and valid
            nav.checkquery(start);
            
            if opt.animate
                nav.plot();
                hold on
            end
            
            % iterate using the next() method until we reach the goal
            robot = start(:);
            path = [];
            while true
                if opt.animate
                    plot(robot(1), robot(2), 'g.', 'MarkerSize', 12);
                    drawnow
                end
                
                % move to next point on path
                robot = nav.next(robot);
                
                % are we there yet?
                if isempty(robot)
                    % yes, exit the loop
                    break
                else
                    % no, append it to the path
                    path = [path robot(:)];
                end
                
            end
            
            % only return the path if required
            if nargout > 0
                pp = path';
            end
        end
        
        % invoked by Navigation.step
        function n = next(ds, current)

            if ds.changed
                error('Cost map has changed, replan');
            end
            X = sub2ind(size(ds.costmap), current(2), current(1));
            X = ds.b(X);
            if X == 0
                n = [];
            else
                [r,c] = ind2sub(size(ds.costmap), X);
                n = [c;r];
            end
        end

        function plan(ds, varargin)
            %Dstar.plan Plan path to goal
            %
            % DS.plan(GOAL) create a D* plan to reach the goal from all free cells
            % in the map.
            %
            % DS.plan() updates a D* plan after changes to the costmap. The goal is
            % as specified in the last call to this method.
            %
            %
            % Note::
            % - If a path has already been planned, but the costmap was
            %   modified, then reinvoking this method will replan,
            %   incrementally updating the plan at lower cost than a full
            %   replan.
            
            opt.progress = true;
            opt.animate = false;
            [opt,args] = tb_optparse(opt, varargin);
            
            if length(args) > 0
                goal = args{1};
                ds.setgoal(goal);
                ds.reset();
                % keep goal in index rather than row,col format
                ds.G = sub2ind(size(ds.occgridnav), goal(2), goal(1));
                ds.INSERT(ds.G, 0, 'goalset');
                ds.h(ds.G) = 0;
                title = 'D* planning';
            else
                title = 'D* replanning';
            end


            ds.niter = 0;
            if opt.progress
                % for replanning we don't really know how many iterations, so scale it to
                % the worst case, a full replan
                h = waitbar(0, title, ...
                    'CreateCancelBtn', 'setappdata(gcbf, ''canceling'', 1)');
                setappdata(h, 'canceling', 0);
            end
            
            % number of free cells, upper bound on number of iterations, trapped free
            % cells will never be reached
            nfree = prod(size(ds.occgridnav)) - sum(sum(ds.occgridnav > 0));
            nupdate = round(nfree/100);
            
            while true
                
                ds.niter = ds.niter + 1;
                if opt.progress && mod(ds.niter, nupdate) == 0
                    if getappdata(h, 'canceling');
                        break;
                    end
                    waitbar(ds.niter/nfree);
                    
                    if opt.animate
                        idisp(ds.h);
                        drawnow
                    end
                end
                

                
                if ds.PROCESS_STATE() < 0
                    break;
                end
                
            end
            if opt.progress
                delete(h);
            end
            ds.changed = false;
        end

        function c = distancemap_get(ds)
        %Dstar.distancemap_get Get the current distance map
        %
        % C = DS.distancemap_get() is the current distance map.  This map is the same size
        % as the occupancy grid and the value of each element is the shortest distance 
        % from the corresponding point in the map to the current goal.  It is computed
        % by Dstar.plan.
        %
        % See also Dstar.plan.
            c = ds.h;
        end

        % functions should be more consistently named:
        %   costmap_set
        %   costmap_get
        %   costmap_modify

        function c = costmap_get(ds)
        %Dstar.costmap_get Get the current costmap
        %
        % C = DS.costmap_get() is the current costmap.  The cost map is the same size
        % as the occupancy grid and the value of each element represents the cost
        % of traversing the cell.  It is autogenerated by the class constructor from
        % the occupancy grid such that:
        % - free cell (occupancy 0) has a cost of 1
        % - occupied cell (occupancy >0) has a cost of Inf
        %
        % See also Dstar.costmap_set, Dstar.costmap_modify.

            c = ds.costmap;
        end

        function costmap_set(ds, costmap)
        %Dstar.costmap_set Set the current costmap
        %
        % DS.costmap_set(C) sets the current costmap.  The cost map is the same size
        % as the occupancy grid and the value of each element represents the cost
        % of traversing the cell.  A high value indicates that the cell is more costly
        % (difficult) to traverese.  A value of Inf indicates an obstacle.
        %
        % Notes::
        % - After the cost map is changed the path should be replanned by 
        %   calling DS.plan(). 
        %
        % See also Dstar.costmap_get, Dstar.costmap_modify.
            if ~all(size(costmap) == size(ds.occgridnav))
                error('costmap must be same size as occupancy grid');
            end
            ds.costmap = costmap;
            ds.changed = true;
        end

        function modify_cost(ds, xy, newcost)
        %Dstar.modify_cost Modify cost map
        %
        % DS.modify_cost(X, Y, cost)
                %Dstar.costmap_modify Modify cost map
        %
        % DS.costmap_modify(P, NEW) modifies the cost map at P=[X,Y] to
        % have the value NEW.  If P (2xM) and NEW (1xM) then the cost of
        % the points defined by the columns of P are set to the corresponding
        % elements of NEW.
        %
        % Notes::
        % - After one or more point costs have been updated the path
        %   should be replanned by calling DS.plan(). 
        % - Replaces modify_cost, same syntax.
        %
        % See also Dstar.costmap_set, Dstar.costmap_get.
        %
        % See also Dstar.costmap_set, Dstar.costmap_get.

            function modify(ds, x, y, newcost)
                X = sub2ind(size(ds.costmap), y, x);
                ds.costmap(X) = newcost;
                
                if ds.t(X) == ds.CLOSED
                    ds.INSERT(X, ds.h(X), 'modifycost');
                end
            end
            
            if all(size(xy) == [2 2]) && numel(newcost) == 1
                % a rectangular region is specified
                for xx=xy(1,1):xy(1,2)
                    for yy=xy(2,1):xy(2,2)
                        if ~isinf(ds.costmap(yy,xx))
                        modify(ds, xx, yy, newcost);
                        end
                    end
                end
            elseif numcols(xy) == numel(newcost)
                % a set of column vectors specifying the points to change
                for i=1:numcols(xy)
                    modify(ds, xy(1,i), xy(2,i), newcost(i));
                end
            else
                error('length of x, y and newcost must match');
            end

            ds.changed = true;
        end
    end % public methods

    methods (Access=protected)

        function occgrid2costmap(ds, og, cost)
            if nargin < 3
                cost = 1;
            end
            ds.costmap = og;
            ds.costmap(ds.costmap==1) = Inf;      % occupied cells have Inf driving cost
            ds.costmap(ds.costmap==0) = cost;     % unoccupied cells have driving cost
        end

        % The main D* function as per the Stentz paper, comments Ln are the original
        % line numbers.
        function r = PROCESS_STATE(d)

            %% states with the lowest k value are removed from the
            %% open list
            X = d.MIN_STATE();                          % L1

            if isempty(X)                               % L2
                r = -1;
                return;
            end

            k_old = d.GET_KMIN(); d.DELETE(X);          % L3

            if k_old < d.h(X)                           % L4
                d.message('k_old < h(X):  %f %f\n', k_old, d.h(X));
                for Y=d.neighbours(X)                   % L5
                    if (d.h(Y) <= k_old) && (d.h(X) > d.h(Y)+d.c(Y,X))  % L6
                        d.b(X) = Y;
                        d.h(X) = d.h (Y) + d.c(Y,X);                    % L7
                    end
                end
            end

            %% can we lower the path cost of any neighbours?
            if k_old == d.h(X)                          % L8
                d.message('k_old == h(X): %f\n', k_old);
                for Y=d.neighbours(X)                   % L9
                    if (d.t(Y) == d.NEW) || ...                         % L10-12
                            ( (d.b(Y) == X) && (d.h(Y) ~= (d.h(X) + d.c(X,Y))) ) || ...
                            ( (d.b(Y) ~= X) && (d.h(Y) > (d.h(X) + d.c(X,Y))) )
                        d.b(Y) = X; d.INSERT(Y, d.h(X)+d.c(X,Y), 'L13');   % L13
                    end
                 end
            else                                        % L14
                d.message('k_old > h(X)');
                for Y=d.neighbours(X)                   % L15
                    if (d.t(Y) == d.NEW) || ( (d.b(Y) == X) && (d.h(Y) ~= (d.h(X) + d.c(X,Y))) )
                        d.b(Y) = X; d.INSERT(Y, d.h(X)+d.c(X,Y), 'L18');   % L18
                    else
                        if ( (d.b(Y) ~= X) && (d.h(Y) > (d.h(X) + d.c(X,Y))) )
                            d.INSERT(X, d.h(X), 'L21');                    % L21
                        else
                            if (d.b(Y) ~= X) && (d.h(X) > (d.h(Y) + d.c(Y,X))) && ...
                                    (d.t(Y) == d.CLOSED) && d.h(Y) > k_old
                                d.INSERT(Y, d.h(Y), 'L25');                % L25
                            end
                        end
                    end
                 end
            end
            
            r = 0;
            return;
        end % process_state(0

        function kk = k(ds, X)
            i = ds.openlist(1,:) == X;
            kk = ds.openlist(2, i);
        end

        % add node to open list
        function INSERT(ds, X, h_new, where)

            % where is for diagnostic purposes only
            ds.message('insert (%s) %d = %f\n', where, X, h_new);

            i = find(ds.openlist(1,:) == X);
            if length(i) > 1
                error('D*:INSERT: state in open list %d times', X);
            end

            if ds.t(X) == ds.NEW
                k_new = h_new;
                % add a new column to the open list
                ds.openlist = [ds.openlist [X; k_new]];
            elseif ds.t(X) == ds.OPEN
                k_new = min( ds.openlist(2,i), h_new );
            elseif ds.t(X) == ds.CLOSED
                k_new = min( ds.h(X), h_new );
                % add a new column to the open list
                ds.openlist = [ds.openlist [X; k_new]];
            end

            if numcols(ds.openlist) > ds.openlist_maxlen
                ds.openlist_maxlen = numcols(ds.openlist);
            end

            ds.h(X) = h_new;
            ds.t(X) = ds.OPEN;
        end

        % remove node from open list
        function DELETE(ds, X)
            ds.message('delete %d\n', X);
            i = find(ds.openlist(1,:) == X);
            if length(i) ~= 1
                error('D*:DELETE: state %d doesnt exist', X);
            end
            if length(i) > 1
                disp('hello')
            end
            ds.openlist(:,i) = []; % remove the column
            ds.t(X) = ds.CLOSED;
        end

        % return the index of the open state with the smallest k value
        function ms = MIN_STATE(ds)
            if isempty(ds.openlist)
                ms = [];
            else
                % find the minimum k value on the openlist
                [~,i] = min(ds.openlist(2,:));

                % return its index
                ms = ds.openlist(1,i);
            end
        end

        function kmin = GET_KMIN(ds)
            kmin = min(ds.openlist(2,:));
        end

        % return the cost of moving from state X to state Y
        function cost = c(ds, X, Y)
            [r,c] = ind2sub(size(ds.costmap), [X; Y]);
            dist = sqrt(sum(diff([r c]).^2));
            dcost = (ds.costmap(X) + ds.costmap(Y))/2;

            cost = dist * dcost;
        end

        % return index of neighbour states as a row vector
        function Y = neighbours(ds, X)
            dims = size(ds.costmap);
            [r,c] = ind2sub(dims, X);

            % list of 8-way neighbours
            Y = [r-1 r-1 r-1 r r  r+1 r+1 r+1; c-1 c c+1 c-1 c+1 c-1 c c+1];
            k = (min(Y)>0) & (Y(1,:)<=dims(1)) & (Y(2,:)<=dims(2));
            Y = Y(:,k);
            Y = sub2ind(dims, Y(1,:)', Y(2,:)')';
        end

    end % protected methods
end % classdef
