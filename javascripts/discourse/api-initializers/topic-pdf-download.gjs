import { apiInitializer } from "discourse/lib/api";
import TopicPdfButton from "../components/topic-pdf-button";

export default apiInitializer((api) => {
  const outlet = settings.button_location || "topic-navigation";

  api.renderInOutlet(
    outlet,
    <template>
      <TopicPdfButton @outletArgs={{@outletArgs}} />
      {{! For wrapper outlets (e.g. post-content-cooked-html), re-render
          the original wrapped content so it isn't replaced by our button. }}
      {{#if @defaultContent}}
        <@defaultContent />
      {{/if}}
    </template>
  );
});
