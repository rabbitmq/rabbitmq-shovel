dispatcher_extensions.push(function(sammy) {
        sammy.get('#/shovel-status', function() {
                render({'shovels': '/shovel-status'},
                       'shovel-status', '#/shovel-status');
            });
});

$("#tabs").append('<li class="administrator-only"><a href="#/shovel-status">Shovel Status</a></li>');
